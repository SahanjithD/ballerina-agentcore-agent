# Ballerina agents on Amazon Bedrock AgentCore: every workaround

What it takes to get a Ballerina agent (`ballerina/ai`) and a Ballerina MCP server to the
same level of governance, observability and evaluation on AgentCore as a Python agent,
with the code and configuration for each step. Everything marked ✅ was proven on a live
deployment in `us-east-1`; anything else says what is missing.

Hosting the tools themselves (MCP server on AgentCore Runtime, REST API on Lambda) is
covered separately in [RECREATE.md](RECREATE.md). Deployment basics are in
[DEPLOY.md](DEPLOY.md).

Versions: Ballerina 2201.13.5, `ballerina/ai` 1, `ballerinax/ai.openai` 1.4.1,
`ballerinax/ai.anthropic` 1.3.5, `ballerina/mcp` 1.3.0, OpenTelemetry Collector contrib.

---

## Summary

| Area | Status | What Ballerina needs |
|---|---|---|
| Model calls through the Gateway (OpenAI) | ✅ | Nothing: pass the Gateway token as the API key |
| Model calls through the Gateway (Anthropic) | ✅ | A loopback forwarder (§1.3) |
| Cedar policy on tool and model calls | ✅ | Target names without hyphens (§2.1) |
| Tool-menu filtering | ✅ | Nothing |
| Guardrails in Cedar on tool input | ✅ | Nothing |
| Guardrails in Cedar on tool output | ⚠️ | Only ever observed in LOG_ONLY |
| Guardrails on the model conversation | ✅ / ⬜ | Via `ApplyGuardrail` in code (§2.6); via Gateway policy not yet tested |
| Temporal (session-aware) policies | ❌ | `ai:McpToolKit` cannot send the session header (§2.7) |
| Tools defined inside the agent | ❌ | AWS cannot see them, same as for Python |
| Traces in CloudWatch GenAI Observability | ✅ | A collector in the container (§3) |
| Evaluations, session and trace level | ✅ | Two collector rewrites (§4) |
| Evaluations, tool-call level | ❌ | Fails with no diagnostic |

The pattern: anything enforced **at the Gateway** works for Ballerina exactly as for any
other language. Gaps appear only where the **client** must do something, such as send a
header, sign a request or emit a particular telemetry shape.

---

## 1. Model calls through the Gateway

Routing the agent's model calls through an AgentCore Gateway **inference target** puts
the model conversation under the same Cedar policies and guardrails as tool calls, and
moves the provider's API key into the Gateway's token vault. The agent container then
holds no provider key at all.

### 1.1 Gateway side

1. **AgentCore Identity**: create an **API key** credential provider with the provider's
   key (for example `openai-key`).
2. **Gateway → Add target**: type **Inference**, pick the connector (`openai`,
   `anthropic` or `bedrock-mantle`), and select that credential provider. Wait for
   `READY`. If the key is invalid the target goes to `UPDATE_UNSUCCESSFUL` with
   `Failed to discover models ... HTTP 401`.
3. **Gateway service role**: it needs **two** grants to read the key, and each one fails
   separately:

```json
{
  "Sid": "ReadInferenceApiKey",
  "Effect": "Allow",
  "Action": "bedrock-agentcore:GetResourceApiKey",
  "Resource": "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:token-vault/default/apikeycredentialprovider/openai-key"
},
{
  "Sid": "ReadInferenceApiKeySecret",
  "Effect": "Allow",
  "Action": "secretsmanager:GetSecretValue",
  "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:bedrock-agentcore-identity!default/apikey/openai-key-*"
}
```

The agent sees a missing grant as an HTTP 400 whose body names the Gateway role and the
denied action, for example `Failed to fetch outbound api key ... not authorized to
perform: bedrock-agentcore:GetResourceApiKey`. Copy the exact secret ARN from the error
or from the credential provider's details page.

### 1.2 Agent side: OpenAI (no workaround)

`openai:ModelProvider` sends its key as `Authorization: Bearer`, which is exactly what the
Gateway's `CUSTOM_JWT` authorizer reads. So the Gateway token *is* the API key:

```ballerina
import ballerinax/ai.openai;

configurable openai:OPEN_AI_MODEL_NAMES modelType = openai:GPT_4_1;
// Ends in /v1: the provider posts to {serviceUrl}/chat/completions.
configurable string inferenceUrl = "https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/inference/v1";

isolated function mintGatewayToken() returns string|error {
    http:Client tokenClient = check new (mcpTokenUrl);
    http:Request request = new;
    request.setTextPayload(string `grant_type=client_credentials&client_id=${mcpClientId}` +
            string `&client_secret=${mcpClientSecret}`, "application/x-www-form-urlencoded");
    // Open record: Cognito also returns expires_in and token_type.
    record {string access_token;} token = check tokenClient->post("", request);
    return token.access_token;
}

final ai:ModelProvider model =
    check new openai:ModelProvider(check mintGatewayToken(), modelType, inferenceUrl);
```

**Limitation:** the provider's auth is a fixed token, so it cannot renew it. Cognito
tokens last one hour, so a container that lives longer starts failing model calls. The
Anthropic forwarder below does not have this problem.

### 1.3 Agent side: Anthropic (loopback forwarder)

`anthropic:ModelProvider` hardcodes `x-api-key` (`model-provider.bal:124`, 1.3.5) and
has no auth option, so a Gateway token passed as its key never reaches the authorizer
and the request gets a 401. The provider calls a forwarder on loopback instead, and the
forwarder resends the request to the Gateway with `Authorization: Bearer`, renewing the
token itself:

```ballerina
import ballerinax/ai.anthropic;

// Ends in /v1: the provider posts to {serviceUrl}/messages.
configurable string inferenceUrl = "https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/inference/v1";

final http:OAuth2ClientCredentialsGrantConfig oauthAuth =
    {tokenUrl: mcpTokenUrl, clientId: mcpClientId, clientSecret: mcpClientSecret};

// Attaches the bearer token and renews it before expiry.
final http:Client inferenceGateway = check new (inferenceUrl, auth = oauthAuth);

// Loopback only: this endpoint attaches Gateway credentials.
service /v1 on new http:Listener(9091, host = "127.0.0.1") {
    resource function post messages(http:Request req) returns http:Response|error {
        req.removeHeader("x-api-key");
        req.removeHeader("host");
        return inferenceGateway->forward("/messages", req);
    }
}

// The key is a placeholder that only reaches the forwarder, which strips it.
final ai:ModelProvider model =
    check new anthropic:ModelProvider("unused", modelType, "http://127.0.0.1:9091/v1");
```

Proven: requests reached Anthropic through the Gateway with the key injected from the
vault. Upstream issue: [wso2/product-integrator#2573](https://github.com/wso2/product-integrator/issues/2573).

**Why not a Gateway interceptor Lambda:** the request interceptor runs *after* inbound
authentication ("After inbound authentication succeeds, the gateway invokes the request
Lambda interceptor", [AWS Security blog](https://aws.amazon.com/blogs/security/implement-custom-authentication-for-tools-integration-using-request-lambda-interceptor-in-agentcore-gateway/)),
so a request carrying only `x-api-key` is rejected before any interceptor runs. The only
documented alternative is to set the Gateway's inbound auth to `NONE` and have the
interceptor validate the JWT itself. That makes the Lambda the Gateway's only protection,
so it isn't recommended just to fix one header.

---

## 2. Governance: AgentCore Policy (Cedar)

### 2.1 Target names must not contain hyphens

**Symptom.** Every `CreatePolicy` ends in `CREATE_FAILED` with:

```
Policy references an action that does not exist on the target gateway.
Verify the target and tool names, then try again.
```

This happens for every action, including tools on other targets, in both `ENFORCE` and
`LOG_ONLY` modes. Nothing is logged: the Gateway emits no span, and no log group
records the validation.

**Cause.** Every tool is exposed as `<target>___<tool>`, and Cedar's schema generator
rejects a hyphen in any tool name with `unexpected token '-'`. One bad name fails the
whole generation, so no action exists at all. Reproducible locally with AWS's
open-source generator:

```bash
python3 -m venv venv && ./venv/bin/pip install cedar-policy-mcp-schema-generator==0.6.1
```

```python
from cedar_mcp_schema_generator import generate_schema
stub = '''namespace AgentCore {
  @mcp_principal entity User;
  @mcp_resource entity Gateway;
  action "call_tool" appliesTo { principal: [User], resource: [Gateway] };
}'''
tool = {"name": "my-target___whoAmI", "description": "x",
        "inputSchema": {"type": "object", "properties": {}}}
print(generate_schema(stub, [tool]))   # isOk: False, "unexpected token `-`"
tool["name"] = "myTarget___whoAmI"
print(generate_schema(stub, [tool]))   # isOk: True
```

To check a live Gateway, feed it the `tools` array from a `tools/list` response
(§5.2).

**Fix.** Name targets in camelCase (`ballerinaMcpServer`). Target names may contain
**only letters, digits and hyphens** (`([0-9a-zA-Z][-]?){1,100}`), so underscores are
rejected too.

**Renaming is destructive in the console.** Saving a new name on the Gateway page
deleted the old targets, then failed to recreate them when the name was invalid. Back up
each target first (`get-gateway-target`) or use `update-gateway-target --name`, which
renames in place. Renaming changes every tool name for that target: update or delete
**every** policy that names the old tools (see §2.4 for what stale ones break), and
restart the agent (`ai:McpToolKit` lists tools once, at startup).

### 2.2 Validation mode for intentionally broad permits

Once the tool list is valid, a permit that names one action but allows any principal
fails a separate check:

```
Overly Permissive: Policy Engine will allow every request for the specified principal
(AgentCore::OAuthUser), action (...) and resource (...) combination
```

When that breadth is intended, create the policy with `IGNORE_ALL_FINDINGS`. The action
names are still checked in this mode; only these warnings are skipped:

```bash
aws bedrock-agentcore-control create-policy --region <REGION> \
  --policy-engine-id <engine-id> --name permit_whoami \
  --enforcement-mode ACTIVE --validation-mode IGNORE_ALL_FINDINGS \
  --definition file://permit.json
# permit.json: {"cedar": {"statement": "permit (principal, action == AgentCore::Action::\"ballerinaMcpServer___whoAmI\", resource == AgentCore::Gateway::\"<gateway-arn>\");"}}
```

`CreatePolicy` returns `CREATING` and validates afterwards, so check
`get-policy ... --query status` about 15 seconds later. A failed create still takes its
name: the next attempt with the same name gets `ConflictException` until the failed
policy is deleted.

### 2.3 Action names

| Target type | Action | Example (proven) |
|---|---|---|
| MCP server / OpenAPI | `<target>___<tool>` | `ballerinaMcpServer___whoAmI` |
| Inference, OpenAI connector | `<target>___POST:/v1/chat/completions` | `anthropic___POST:/v1/chat/completions` |
| Inference, Anthropic connector | `<target>___POST:/v1/messages` | not yet confirmed |

The inference action has **no `/inference` prefix**, and it uses the target's *name*.
Changing a target's connector (here, from Anthropic to OpenAI) keeps the old name. Write
one policy per action: `action in [...]` across targets is reported to fail.

### 2.4 Tool-menu filtering

With enforcement on, `tools/list` returns only the tools the caller could be permitted to
call. The Gateway asks the engine (`PartiallyAuthorizeActions`) on every listing. Proven:
with a single `permit` for `ballerinaMcpServer___whoAmI`, the listing returned exactly that
one tool out of 8. The listing does not evaluate tool arguments, so a listed tool can still
be denied when it's called. The decision is visible in the Gateway's spans (§5.4) as
`aws.agentcore.policy.allowed_tools` and `denied_tools`.

**Stale policies turn listing filtering off.** While five policies still named actions
that no longer existed (left over from renamed targets), enforce-mode `tools/list`
returned **all 8 tools**, and the engine reported all 8 as allowed. Calls were still
enforced: calling an unpermitted tool returned `Tool call not allowed due to policy
enforcement [No policy applies to the request (denied by default).]`. So it isn't an
access bypass, but the model is shown tools it cannot use. Deleting the stale policies
restored filtering immediately. Check with `list-policies` / `get-policy` that every
policy names a current `<target>___<tool>`.

**Expected validation findings.** A `forbid` on a tool nothing permits yet fails with
"Overly Restrictive", and an action-scoped `permit` fails with "Overly Permissive". Both
are semantic findings; create with `--validation-mode IGNORE_ALL_FINDINGS` when the rule
is intended.

### 2.5 Guardrails inside Cedar (tool traffic)

Guardrail checks are written into the policy; they are not a setting on the Gateway or
the target. Guardrail policies use AWS's extended policy language: via the API, pass the
statement under `{"policy": {"statement": ...}}`, not `{"cedar": ...}` (with `cedar`, the
parse fails with ``unexpected token `guardrails` ``). Working syntax (proven, EMAIL scored
`1.0`):

```cedar
forbid (
  principal,
  action == AgentCore::Action::"ballerinaRestApi___greetPerson",
  resource == AgentCore::Gateway::"<gateway-arn>"
)
when guardrails {
  BedrockGuardrails::SensitiveInformation(["EMAIL"], [context.input.name])
    .maxConfidenceScore().greaterThan(decimal("0.0"))
};
```

The same form over `context.output.<field>` (suppressing a tool's response) was only ever
observed logging, never blocking. AWS documents that guardrail policies also apply to
inference targets (`POST /inference`), which would guard the model conversation at the
Gateway; that has not been tested yet.

### 2.6 Guarding the model conversation in code (`ApplyGuardrail`)

Before inference targets were available, the prompt and the answer were screened in the
agent with Bedrock `ApplyGuardrail`, which works with any model provider. It is proven
(blocked prompts return the guardrail's own message) and removed from this repo in favour
of the Gateway. The core of it:

```ballerina
import ballerinax/aws;
import ballerinax/aws.auth;

final string bedrockHost = aws:resolveEndpointHost("bedrock-runtime", awsRegion);
final auth:CredentialProvider awsCredentials = check new (auth:DEFAULT_CREDENTIALS);
final http:Client bedrockRuntime = check new (aws:resolveEndpoint("bedrock-runtime", awsRegion));

// () if clean; otherwise the text to return instead (masked, or the blocked message).
isolated function screen(string text, "INPUT"|"OUTPUT" direction) returns string?|error {
    string path = string `/guardrail/${guardrailId}/version/${guardrailVersion}/apply`;
    json requestBody = {"source": direction, "content": [{"text": {"text": text}}]};
    byte[] payload = requestBody.toJsonString().toBytes();
    // Signing name is `bedrock`, not `bedrock-runtime`.
    map<string> headers = check auth:getSignedHeaders({method: "POST", host: bedrockHost,
            path, headers: {"content-type": "application/json"}, payload},
            check awsCredentials.getCredentials(), awsRegion, "bedrock");
    // Open record: the response carries more fields than these.
    record {string action; record {string text;}[] outputs = [];} response =
            check bedrockRuntime->post(path, payload, headers, "application/json");
    return response.action == "GUARDRAIL_INTERVENED" ? response.outputs[0].text : ();
}
```

Call it on the prompt before `agent.run()` and on the answer after, and fail closed on
error. Things that caused failures:
- `source` is a reserved word in Ballerina.
- A closed response record rejects the extra `actionReason` field, which failed every
  call.
- `ai:ModelProvider.generate` is dependently typed, so a decorating provider can't be
  written in Ballerina. Screening therefore happens at the service boundary, not per
  model turn.
- Cross-Region guardrails authorize on the **guardrail-profile ARN in every destination
  Region**, not just the guardrail ARN:

```json
{ "Effect": "Allow", "Action": "bedrock:ApplyGuardrail",
  "Resource": ["arn:aws:bedrock:<REGION>:<ACCOUNT>:guardrail/*",
               "arn:aws:bedrock:*:<ACCOUNT>:guardrail-profile/*"] }
```

### 2.7 Temporal policies: blocked for Ballerina

Session-aware Cedar policies need `x-amzn-bedrock-agentcore-policy-session-id` on
**every** Gateway request, and "if the associated policy engine contains a temporal
policy, requests without a session ID fail with a validation error". So adding one breaks
every tool call from an agent that doesn't send the header. `ai:McpToolKit` →
`mcp:StreamableHttpClientTransportConfig` → `http:ClientConfiguration` has no way to add
a custom header, and the toolkit is built once at module level, so it couldn't carry a
per-conversation value anyway. This needs an upstream change to `ballerina/mcp` or
`ballerina/ai`.

### 2.8 Tools defined inside the agent

`@ai:AgentTool` functions run in-process and never cross the Gateway, so no AWS control
applies to them, the same as local tools in any framework. `ai:RequiresApproval` on the
annotation (a `boolean` or a predicate taking the tool's own parameters) is the
in-process control. To put a tool under AWS governance, host it behind the Gateway (see
RECREATE.md).

---

## 3. Observability

`ballerina/otel` exports OTLP but cannot SigV4-sign, and the X-Ray OTLP endpoint accepts
nothing else. So each container runs an OpenTelemetry Collector (contrib) as a second
process: Ballerina sends to `127.0.0.1:4317` unsigned, and the collector signs and
forwards. AgentCore gives you a container, not a pod, so this cannot be a sidecar.

| File | Purpose |
|---|---|
| [Dockerfile](Dockerfile) | Copies `otelcol-contrib`, the config and `start.sh`; `ENTRYPOINT ["/app/start.sh"]` |
| [start.sh](start.sh) | Reads AgentCore's injected `OTEL_RESOURCE_ATTRIBUTES`, starts the collector in the background, and runs the agent in the foreground |
| [observability.toml](observability.toml) | Copied into the image as `Config.toml`: tracing on, OTLP to loopback, JSON logs |
| [otel-collector.yaml](otel-collector.yaml) | The processors below |

Use **contrib, not ADOT**: ADOT v0.50.0 does not ship the `transform` processor.

The processors, each added for a specific failure:

| Processor | Why |
|---|---|
| `filter/drop_health` | `/ping` every 2 s would otherwise become billable spans |
| `attributes/genai_token_types` | Ballerina's span API is string-only, and the dashboard can't sum `"1986"`, so "Total tokens" read 0 |
| `transform/genai_total_tokens` | Adds `gen_ai.usage.total_tokens`, which AWS's queries use |
| `transform/scope_name` | Evaluations only read scopes named `opentelemetry.instrumentation.*`; Ballerina's scope is `otel` (§4) |
| `transform/genai_eval_aliases` | Copies prompt, answer and tool I/O to the names Evaluations read (§4) |
| `resource/agent_identity` | Copies AgentCore's own identity attributes onto the spans; without `deployment.environment.name` they are classed `Generic` and don't roll up |
| `attributes/agentcore_origin` | `aws.xray.origin` / `aws.resource.type` = `AWS::BedrockAgentCore::Runtime` |
| `attributes/session_id` | Copies `gen_ai.conversation.id` to `session.id`, which AWS uses for session correlation |

Keep the pipeline's processor list on **one line**: `start.sh` removes the
identity processors with `sed 's|, <name>||'` when `OTEL_RESOURCE_ATTRIBUTES` is
missing, because an empty `${env:...}` makes the collector exit.

**The MCP server** uses the same pattern ([tools/mcp-server/](tools/mcp-server/)), with
only the drop-health and identity processors. Result: 6 spans per call became 149,
including one per tool (`/mcp:whoAmI`).

**Config.toml is strict.** An unknown key is **fatal**, not a warning. Writing
`[ballerinai.otel]` or `[ballerina.observe.tracer] name` put the MCP server into a crash
loop, and the only symptom at the caller was a 408. Run the image locally once before
deploying.

**Runtime role:** needs X-Ray write access and CloudWatch Logs; see
[deploy/execution-policy.json](deploy/execution-policy.json).

---

## 4. Evaluation

AgentCore Evaluations (online, with the runtime's CloudWatch log group as the data source)
scores sessions and traces from the spans. With Ballerina's spans as emitted, every score
was a meaningless `1.0`: the judge's explanation said *"Both the task and the candidate
response are empty strings"*. Two causes, both fixed in the collector:

1. **Scope name.** Generic framework support only reads spans whose `scope.name` starts
   with `opentelemetry.instrumentation.` or `openinference.instrumentation.`.
   `ballerina/otel` names its scope `otel`.

   ```yaml
   transform/scope_name:
     trace_statements:
       - context: scope
         statements:
           - set(scope.name, "opentelemetry.instrumentation.ballerina") where scope.name == "otel"
   ```

2. **Attribute names.** `ballerina/ai` puts the prompt and answer on the `invoke_agent`
   span as `gen_ai.input.messages` / `gen_ai.output.messages`, the names Evaluations only
   reads on *inference* spans. On `invoke_agent` it expects `gen_ai.task.input` /
   `gen_ai.task.output`. Tool spans use `gen_ai.tool.arguments` / `gen_ai.tool.output`
   where Evaluations expects `gen_ai.tool.call.arguments` / `gen_ai.tool.call.result`.
   The collector copies them across (see `transform/genai_eval_aliases`, which also sets
   the any-scope fallback `agentcore.invocation.user_prompt` / `agent_response`).

After the fix, results were varied, with real explanations: Correctness 0.88,
GoalSuccessRate 0.75, Helpfulness 0.56, InstructionFollowing 1.0, ResponseRelevance 1.0.

**Always read the judge's explanation, not just the score.** A uniform 1.0 across every
evaluator means the judge received empty input.

**Open:** `TOOL_CALL`-level evaluators fail with no diagnostic. The likely cause is that
Ballerina's spans don't record the list of tools that were available to the model. Not
yet confirmed.

---

## 5. Test recipes

### 5.1 Mint a Gateway token without printing the secret

```bash
umask 077
aws bedrock-agentcore-control get-agent-runtime --region <REGION> --agent-runtime-id <id> \
  --query environmentVariables --output json > env.json
python3 - <<'PY' > .tok
import json, urllib.request, urllib.parse
e = json.load(open("env.json"))
data = urllib.parse.urlencode({"grant_type": "client_credentials",
    "client_id": e["BAL_CONFIG_VAR_MCPCLIENTID"],
    "client_secret": e["BAL_CONFIG_VAR_MCPCLIENTSECRET"]}).encode()
r = urllib.request.urlopen(urllib.request.Request(e["BAL_CONFIG_VAR_MCPTOKENURL"], data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"}))
print(json.load(r)["access_token"], end="")
PY
rm -f env.json
```

Delete `.tok` when done.

### 5.2 List the Gateway's tools

The Gateway rejects the MCP protocol version many clients default to, so send the header:

```bash
curl -s -X POST "https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp" \
  -H "Authorization: Bearer $(cat .tok)" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Without the header: `Unsupported protocol version: 2025-03-26`. The versions a Gateway
accepts are set in `protocolConfiguration.mcp.supportedVersions`.

### 5.3 Invoke the agent and read the failure

```bash
aws bedrock-agentcore invoke-agent-runtime --region <REGION> --agent-runtime-arn <arn> \
  --runtime-session-id "test-$(date +%s)-00000000000000000000" \
  --content-type application/json \
  --payload "$(echo -n '{"prompt":"Use the whoAmI tool."}' | base64)" out.json
```

A `RuntimeClientError (500)` hides the cause. It's in the runtime's log group
(`/aws/bedrock-agentcore/runtimes/<id>-DEFAULT`) on the `agent run failed` line, whose
`body=` holds the upstream error: Gateway denials, IAM errors and provider errors all
show up there.

### 5.4 See policy decisions

```bash
aws logs filter-log-events --region <REGION> --log-group-name aws/spans \
  --start-time $(( ($(date +%s) - 300) * 1000 )) \
  --filter-pattern '"PartiallyAuthorizeActions"' --query 'events[].message'
```

Look for `aws.agentcore.gateway.policy.mode`, `aws.agentcore.policy.allowed_tools` and
`aws.agentcore.policy.denied_tools`.

---

## 6. Identity

| Hop | Mechanism | Status |
|---|---|---|
| Caller → agent runtime | IAM (SigV4) | ✅ |
| Agent → Gateway | Cognito client credentials, secret in a runtime environment variable | ⚠️ Works; the secret lives in the environment |
| Gateway → MCP runtime / Lambda | Gateway IAM role (SigV4) | ✅ |
| Gateway → model provider | API key from the token vault | ✅ |
| Agent obtaining its token from AgentCore Identity (no secret in the environment) | Workload identity | ⬜ Not yet tested; Ballerina has no AgentCore SDK, so it would be signed HTTP calls, like §2.6 |
