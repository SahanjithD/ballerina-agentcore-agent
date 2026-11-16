# Ballerina agents on AgentCore: gaps in identity, governance, observability and evaluations

What a Ballerina agent (`ballerina/ai`) cannot yet do on Amazon Bedrock AgentCore that a
Python agent can, in four areas. For each gap: what AWS expects, why the existing Ballerina
feature cannot do it (with the library code), the workaround if there is one (with our
code), and the GitHub issue.

This is a living document; see the [change log](#change-log). Last updated: 2026-10-29.

Versions: Ballerina 2201.14.1, `ballerina/ai` 1.16.0, `ballerina/mcp` 1.4.0,
`ballerina/otel` 1.0.0, `ballerina/observe` 1.8.0, `ballerinax/ai.aws.dynamodb` 1.1.0.
Library code below is quoted from those versions.

Related: [PARITY.md](PARITY.md) (every AgentCore feature, all languages),
[BALLERINA-ON-AGENTCORE.md](BALLERINA-ON-AGENTCORE.md) (how each workaround was proven),
[GUIDE.md](GUIDE.md) (deployment steps).

**Status legend**

| Mark | Meaning |
|---|---|
| ✅ | No gap; works with existing Ballerina features |
| 🔧 | Gap, with a working workaround (proven on our deployment unless it says otherwise) |
| ❌ | Gap with no workaround |

---

## Summary

| # | Area | Gap | Status | Issue |
|---|---|---|---|---|
| I1 | Identity | No AgentCore Identity token source | 🔧 [identity.bal](identity.bal) | [#2850](https://github.com/wso2/product-integrator/issues/2850) |
| I2 | Identity | A toolkit cannot take a new token per invocation | 🔧 [gateway_toolkit.bal](gateway_toolkit.bal) | no issue yet |
| I3 | Identity | `ballerina/ai` agent ID works only with WSO2 Identity Server / Asgardeo | Not a gap to fix; explains why I1 is needed | none |
| I4 | Identity | API key, user sign-in (three-legged OAuth) and token exchange flows | 🔧 possible, not built | covered by [#2850](https://github.com/wso2/product-integrator/issues/2850) only for M2M |
| I5 | Identity | DynamoDB memory cannot use the execution role | 🔧 a scoped key in Secrets Manager | [#2835](https://github.com/wso2/product-integrator/issues/2835) |
| G1 | Governance | `ai:McpToolKit` cannot send the policy session header | 🔧 custom toolkit | [#2823](https://github.com/wso2/product-integrator/issues/2823) (closed with this workaround) |
| G2 | Governance | Model providers cannot authenticate to a Gateway inference target | 🔧 loopback forwarder (Anthropic); none for renewal (OpenAI) | [#2573](https://github.com/wso2/product-integrator/issues/2573) |
| G3 | Governance | Durable human approvals only with `ai:ShortTermMemory` | ✅ for our setup; ❌ for a custom `ai:Memory` | [#2597](https://github.com/wso2/product-integrator/issues/2597) |
| G4 | Governance | Tools defined inside the agent are outside Cedar | Same for every language | none |
| O1 | Observability | `ballerina/otel` cannot sign exports (SigV4) | 🔧 collector in the container | no issue yet |
| O2 | Observability | Span attributes are strings only | 🔧 collector converts | [#2818](https://github.com/wso2/product-integrator/issues/2818) |
| O3 | Observability | No flush before the program stops | ❌ | [#2822](https://github.com/wso2/product-integrator/issues/2822) |
| O4 | Observability | `OTEL_RESOURCE_ATTRIBUTES` is not read | 🔧 `start.sh` plus collector | no issue yet |
| O5 | Observability | No baggage, so `session.id` is not on every span | ❌ | no issue yet |
| O6 | Observability | The platform's span and the agent's spans are in different traces | ❌ | no issue yet |
| E1 | Evaluations | Scope name `otel` is not recognised | 🔧 collector renames | no issue yet |
| E2 | Evaluations | Prompt, answer and tool attributes have the wrong names | 🔧 collector copies | no issue yet |
| E3 | Evaluations | Tool-level evaluations fail | ❌ (needs O5) | no issue yet |
| E4 | Evaluations | No client for on-demand and batch evaluation or datasets | 🔧 possible, not built | no issue yet |

**Not gaps.** Getting the Gateway token from AgentCore Identity works today (I1's
workaround), so the agent does not need to hold a client secret. Cedar policy, tool-menu
filtering, guardrails in Cedar, temporal policies (with G1's workaround) and online
evaluations at session and trace level all work for Ballerina.

---

## 1. Identity

### I1. No AgentCore Identity token source 🔧

**What AWS expects.** On each invocation, AgentCore Runtime gives the agent a workload
access token (header `WorkloadAccessToken`). The agent trades it for an OAuth token by
calling Identity's `GetResourceOauth2Token`, signed with SigV4 using the execution role.
The client secret stays in the Identity vault. Python does this with one decorator:

```python
@requires_access_token(provider_name="gateway-cognito", scopes=[], auth_flow="M2M")
async def call_gateway(*, access_token: str): ...
```

**Why existing Ballerina cannot.** The toolkit's `auth` field takes the standard HTTP
client auth configurations, or WSO2's agent ID configuration (`ballerina/ai` `types.bal`):

```ballerina
# Configurations related to client authentication
http:ClientAuthConfig|AgentIdAuthConfig? auth = ();
```

`http:ClientAuthConfig` covers Basic, Bearer, self-signed JWT and the OAuth2 grants
(client credentials, password, refresh token, JWT bearer). None of them makes a
SigV4-signed call to an AWS API carrying a workload access token. `AgentIdAuthConfig` is a
different login altogether (I3).

**Workaround.** One signed HTTP call, [identity.bal](identity.bal), made on every
invocation in [service.bal](service.bal):

```ballerina
json requestBody = {
    resourceCredentialProviderName: gatewayCredentialProvider,
    scopes: [],
    oauth2Flow: "M2M",
    workloadIdentityToken: workloadToken
};
byte[] payload = requestBody.toJsonString().toBytes();
map<string> signedHeaders = check auth:getSignedHeaders({
    method: "POST", host: identityHost, path: "/identities/oauth2/token",
    headers: {"content-type": "application/json"}, payload
}, check awsCredentials.getCredentials(), awsRegion, "bedrock-agentcore");
record {string accessToken?;} response =
        check identityClient->post(path, payload, signedHeaders, "application/json");
```

Note: the Runtime sends `WorkloadAccessToken` only when the caller names a user
(`--runtime-user-id`) or uses JWT inbound auth. This is AWS's design, not a Ballerina gap.

**Fix wanted.** An AgentCore Identity token source in `ballerina/ai` usable by toolkits
and model providers. Issue: [#2850](https://github.com/wso2/product-integrator/issues/2850).

### I2. A toolkit cannot take a new token per invocation 🔧

**What AWS expects.** Identity tokens are short-lived and fetched per invocation, so the
toolkit must send the current invocation's token.

**Why existing Ballerina cannot.** `ai:McpToolKit` connects once, in `init`, with a fixed
`auth`, and `callTool` has no way to receive anything from the current run
(`ballerina/ai` `toolkit.bal`):

```ballerina
public isolated function callTool(mcp:CallToolParams params) returns mcp:CallToolResult|error {
    return self.mcpClient->callTool(params);
}
```

Sending the token as a per-request header is not enough either. During `initialize`,
`ballerina/mcp` sends the `notifications/initialized` message with no way to add headers
(`streamable_http_client.bal`):

```ballerina
check self.sendNotificationMessage(<InitializedNotification>{});
```

and the Gateway answers that message 401 without a token. So the token has to be in the
client's own `auth`, which is fixed per client.

**Workaround.** [gateway_toolkit.bal](gateway_toolkit.bal), built on `ai:McpBaseToolKit`.
The invocation puts its token in `ai:Context`; the toolkit reads it and reconnects only when
the token changes:

```ballerina
@ai:AgentTool
public isolated function callTool(ai:Context ctx, mcp:CallToolParams params)
        returns mcp:CallToolResult|error {
    string? token = ctx.hasKey(GATEWAY_TOKEN_KEY) ? check ctx.getWithType(GATEWAY_TOKEN_KEY) : ();
    mcp:StreamableHttpClient mcpClient = check self.clientFor(token);
    return mcpClient->callTool(params, self.headers);
}
```

**Fix wanted.** A token provider (a function called per request) on `ai:McpToolKit` and
`mcp:StreamableHttpClient`, and headers on notifications. No issue filed yet.

### I3. `ballerina/ai` agent ID works only with WSO2 Identity Server / Asgardeo

Not a gap to fix, but the reason I1 needs its own solution. `ai:Credential {id, secret}`
with a per-tool `AgentIdAuthConfig` logs the agent in through the WSO2 Identity Server /
Asgardeo app-native authentication API (`ballerina/ai` `token.bal`):

```ballerina
map<string> formData = {
    client_id: clientId,
    response_type: CODE,
    scope: scopes,
    redirect_uri: redirectUri,
    response_mode: DIRECT        // POST {baseAuthUrl}/authorize
};
...
params: {
    username: agentCredential.id,
    password: agentCredential.secret   // POST {baseAuthUrl}/authn
}
...
grant_type: AUTHORIZATION_CODE        // POST {baseAuthUrl}/token
```

Three reasons it cannot replace AgentCore Identity:
1. Cognito and AgentCore Identity do not offer `/authorize` with `response_mode=direct`
   or `/authn`.
2. The agent holds a long-lived secret (`agentCredential.secret`), which AgentCore Identity
   exists to remove.
3. There is no hook for another token source.

Untested option: point the Gateway's inbound JWT authorizer at Asgardeo. Agent ID might then
work against the Gateway, but the agent would hold a secret again.

### I4. API key, user sign-in and token exchange flows 🔧 (possible, not built)

**What AWS expects.** Besides M2M, Python offers `@requires_api_key` (`GetResourceApiKey`),
`auth_flow="USER_FEDERATION"` (the user signs in and consents; the agent receives an
authorization URL, then the token), `ON_BEHALF_OF_TOKEN_EXCHANGE`, and
`@requires_iam_access_token` (an STS-issued JWT).

**Why existing Ballerina cannot.** Same reason as I1: no Identity client.

**Workaround.** The API key flow is the same shape as I1: one signed call with a
different path and body. User sign-in also needs a way to hand the authorization URL back
to the person. Our `/invocations` returns one complete JSON answer, so the agent would
have to answer "please sign in at this URL" and expect a second invocation. Neither is
built or tested.

**Issue.** [#2850](https://github.com/wso2/product-integrator/issues/2850) asks for M2M "at
least"; the other flows could be added there.

### I5. DynamoDB memory cannot use the execution role 🔧

**What AWS expects.** Code on AWS uses the temporary credentials of its compute's role, not
long-lived access keys.

**Why existing Ballerina cannot.** `ai.aws.dynamodb` 1.1.0 is built on `aws.dynamodb`
2.3.0, whose configuration accepts only explicit credentials (`records.bal`):

```ballerina
public type ConnectionConfig record {|
    *config:ConnectionConfig;
    never auth?;
    # AWS credentials
    AwsCredentials|AwsTemporaryCredentials awsCredentials;
    # AWS Region
    string region;
|};
```

**Workaround.** A key scoped to the one table, kept in Secrets Manager and read with the
execution role ([agents.bal](agents.bal) `memoryStore`). It is still a long-lived key to
rotate.

**Fix wanted.** Move to `aws.dynamodb` 3.x, which supports `auth:DEFAULT_CREDENTIALS`.
Issue: [#2835](https://github.com/wso2/product-integrator/issues/2835).

---

## 2. Governance

### G1. `ai:McpToolKit` cannot send the policy session header 🔧

**What AWS expects.** Temporal Cedar policies ("at most 3 refunds per session") are
evaluated over a policy session, named by the header
`x-amzn-bedrock-agentcore-policy-session-id`. Once the policy engine holds a temporal
policy, every request without the header fails, `initialize` and `tools/list` included.

**Why existing Ballerina cannot.** `ballerina/mcp` accepts headers, but `ai:McpToolKit`
never passes them (`toolkit.bal`):

```ballerina
mcp:ClientError? initializeRes = self.mcpClient->initialize(info);
mcp:ListToolsResult|error listTools = self.mcpClient->listTools();
return self.mcpClient->callTool(params);
```

**Workaround.** The same custom toolkit as I2 sends the header on every request:

```ballerina
self.headers = {[POLICY_SESSION_HEADER]: policySessionId}.cloneReadOnly();
check mcpClient->initialize({name: "ballerina-agent", version: "1.0.0"}, headers = headers);
mcp:ListToolsResult listed = check mcpClient->listTools(self.headers);
return mcpClient->callTool(params, self.headers);
```

**Issue.** [#2823](https://github.com/wso2/product-integrator/issues/2823), closed: the
maintainers pointed to `ai:McpBaseToolKit` plus `ai:Context` as the way, which is this
workaround. A `headers` option on `ai:McpToolKit` itself was not added.

### G2. Model providers cannot authenticate to a Gateway inference target 🔧

**What AWS expects.** Routing model calls through a Gateway inference target puts them
under Cedar and keeps the provider key in the vault. The Gateway wants
`Authorization: Bearer <token>`, renewed before it expires.

**Why existing Ballerina cannot.** `ai.anthropic` hard-codes its key header:

```ballerina
map<string> headers = {
    "x-api-key": self.apiKey,
    "anthropic-version": ANTHROPIC_API_VERSION,
    "content-type": "application/json"
};
```

`ai.openai` sends the key as a bearer token, so the Gateway accepts it, but the key is fixed
at construction and cannot be renewed when the token expires.

**Workaround.** Anthropic: a loopback forwarder on `127.0.0.1` that swaps the header and
renews the token (proven; [BALLERINA-ON-AGENTCORE.md](BALLERINA-ON-AGENTCORE.md) §1.3).
OpenAI: none for renewal. Today we avoid both by calling Bedrock directly with the execution
role, guarded by a Bedrock guardrail, so model calls are outside Cedar.

**Issue.** [#2573](https://github.com/wso2/product-integrator/issues/2573).

### G3. Durable human approvals only with `ai:ShortTermMemory` ✅ / ❌

**What it is.** A gated tool (`requiresApproval`) pauses the run until a person approves.
The pause (a checkpoint) must survive a restart or a resume in another container.

**Why existing Ballerina falls short.** `ai:Agent` uses the memory's checkpoint methods only
if the memory is the concrete `ai:ShortTermMemory` class (`agent.bal`):

```ballerina
Memory agentMemory = self.memory;
if agentMemory is ShortTermMemory {
    self.checkpointer = agentMemory;
} else {
    self.checkpointer = check new ShortTermMemory();   // in-memory fallback
    ...
}
```

**For us.** We use `ai:ShortTermMemory` with a DynamoDB store, so checkpoints are durable.
The gap appears for a custom `ai:Memory`, for example one backed by AgentCore Memory.
Writing AgentCore Memory as an `ai:ShortTermMemoryStore` instead avoids it.

**Issue.** [#2597](https://github.com/wso2/product-integrator/issues/2597) (treated as an
improvement by the maintainers).

### G4. Tools defined inside the agent are outside Cedar

`@ai:AgentTool` functions run in the agent and never cross the Gateway, so Cedar cannot see
them. The same is true of in-process tools in Python. Not a Ballerina gap. Mitigations: put
risky tools behind the Gateway, or gate them with `requiresApproval`.

---

## 3. Observability

### O1. `ballerina/otel` cannot sign exports (SigV4) 🔧

**What AWS expects.** The X-Ray OTLP endpoint for traces accepts SigV4-signed requests only.
Python and Java use ADOT, which signs.

AgentCore Runtime also runs a managed ADOT collector on `localhost:4318` that signs for the
agent, but it starts only when the entrypoint contains `opentelemetry-instrument`, which is
Python only. For .NET, Java, TypeScript and Ballerina nothing listens there and telemetry is
silently dropped: [aws/agentcore-cli#1270](https://github.com/aws/agentcore-cli/issues/1270)
(open). If that is fixed, the agent could export to it (over HTTP/protobuf, not our gRPC) and
drop its own signing, though the span fixes in O2, E1 and E2 would still need a collector.

**Why existing Ballerina cannot.** The exporter accepts only fixed headers
(`ballerina/otel` `configs.bal`):

```ballerina
configurable string tracesEndpoint = "http://localhost:4317";
configurable string tracesExporterHeaders = "";
configurable string tracesProtocol = "grpc";
```

A SigV4 signature covers each request's body and time, so it cannot be a fixed header.

**Workaround.** An OpenTelemetry Collector runs as a second process in the container; the
agent exports to it on `127.0.0.1:4317` unsigned, and the collector signs and forwards
([otel-collector.yaml](otel-collector.yaml), [start.sh](start.sh)):

```yaml
extensions:
  sigv4auth:
    region: us-east-1
    service: xray
exporters:
  otlp_http:
    traces_endpoint: https://xray.us-east-1.amazonaws.com/v1/traces
    auth:
      authenticator: sigv4auth
```

**Fix wanted.** A SigV4 option in `ballerina/otel`. No issue filed yet.

### O2. Span attributes are strings only 🔧

**Why existing Ballerina cannot.** `ballerina/observe` `natives.bal`:

```ballerina
public isolated function addTagToSpan(string tagKey, string tagValue, int spanId = -1) returns error?
```

So token counts leave as `"329"`, not `329`, and the CloudWatch GenAI dashboard shows 0 total
tokens.

**Workaround.** The collector converts them, and sums the total that AWS's queries expect:

```yaml
attributes/genai_token_types:
  actions:
    - key: gen_ai.usage.input_tokens
      action: convert
      converted_type: int
```

**Issue.** [#2818](https://github.com/wso2/product-integrator/issues/2818).

### O3. No flush before the program stops ❌

`ballerina/otel` owns the tracer provider but exposes no `flush` or `shutdown`, registers no
shutdown hook, and runs the batch exporter on a daemon thread. Spans still queued when the
container stops are lost. On AgentCore every session's microVM stops eventually, so the last
spans of a session can be lost, and with them the material Evaluations scores. No
workaround for spans.

**Issue.** [#2822](https://github.com/wso2/product-integrator/issues/2822) (Priority/High).

### O4. `OTEL_RESOURCE_ATTRIBUTES` is not read 🔧

**What AWS expects.** AgentCore injects `OTEL_RESOURCE_ATTRIBUTES` (service name, the
endpoint's resource id, log group and others). CloudWatch uses them to attribute spans to
the agent. OpenTelemetry SDKs read this variable by default.

**Why existing Ballerina cannot.** `ballerina/otel` takes resource attributes from its own
configuration only (`configurable map<string> tracesResourceAttributes = {}`). Its native
code contains no reference to `OTEL_RESOURCE_ATTRIBUTES`. The values are only known at
runtime, so they cannot be put in `Config.toml` ahead of time.

**Workaround.** [start.sh](start.sh) parses the variable and the collector applies the
values (`resource/agent_identity` in [otel-collector.yaml](otel-collector.yaml)).

**Fix wanted.** Honour the standard variable. No issue filed yet.

### O5. No baggage, so `session.id` is not on every span ❌

**What AWS expects.** AWS's instrumentation puts `session.id` on every span through
OpenTelemetry baggage. Evaluations groups spans by it.

**Why existing Ballerina cannot.** `ballerina/otel` registers only the W3C trace-context
propagator (no baggage propagator), and `ai.observe` records the session as
`gen_ai.conversation.id` on the `invoke_agent` span only.

**Partial workaround.** The collector copies it onto that one span:

```yaml
attributes/session_id:
  actions:
    - key: session.id
      from_attribute: gen_ai.conversation.id
      action: upsert
```

A collector processes spans one at a time and cannot copy an attribute from a parent span
to its children, so the child spans (model calls, tool calls) stay without it. This is what
breaks E3. No issue filed yet.

### O6. The platform's span and the agent's spans are in different traces ❌

CloudWatch shows the platform's `AgentCore.Runtime.Invoke` span and the agent's spans as
separate traces; the Ballerina HTTP listener starts a new trace instead of continuing the
platform's. `ballerina/otel` understands only W3C `traceparent`. Which trace header AgentCore
sends to the container has not been checked, so the exact cause is not confirmed. No
workaround, no issue yet.

---

## 4. Evaluations

### E1. Scope name `otel` is not recognised 🔧

**What AWS expects.** Under generic framework support, Evaluations reads only spans whose
scope name starts with `opentelemetry.instrumentation.` or `openinference.instrumentation.`.
`ballerina/otel` names its scope `otel`, so every span is skipped.

**Workaround.** The collector renames it, only when the value is exactly `otel`:

```yaml
transform/scope_name:
  trace_statements:
    - context: scope
      statements:
        - set(scope.name, "opentelemetry.instrumentation.ballerina") where scope.name == "otel"
```

No issue filed yet.

### E2. Prompt, answer and tool attributes have the wrong names 🔧

**What AWS expects.** On an `invoke_agent` span, Evaluations reads the prompt and answer from
`gen_ai.task.input` / `gen_ai.task.output`; on an `execute_tool` span, from
`gen_ai.tool.call.arguments` / `gen_ai.tool.call.result`.

**What Ballerina emits.** `ai.observe` puts them under `gen_ai.input.messages` /
`gen_ai.output.messages` and `gen_ai.tool.arguments` / `gen_ai.tool.output`. Evaluations
then finds empty strings, and the judge scores two empty strings as a perfect match.

**Workaround.** The collector copies them to the expected names (and to
`agentcore.invocation.*`, the fallback Evaluations reads from any scope):

```yaml
- set(span.attributes["gen_ai.task.input"], span.attributes["gen_ai.input.messages"]) where span.attributes["gen_ai.operation.name"] == "invoke_agent" and span.attributes["gen_ai.input.messages"] != nil
- set(span.attributes["gen_ai.tool.call.arguments"], span.attributes["gen_ai.tool.arguments"]) where span.attributes["gen_ai.operation.name"] == "execute_tool" and span.attributes["gen_ai.tool.arguments"] != nil
```

No issue filed yet.

### E3. Tool-level evaluations fail ❌

Session- and trace-level evaluators read only the `invoke_agent` span, which carries
`session.id` after the collector, so they work. Tool-level evaluators read the child spans,
which do not carry it (O5). Online, they fail with no diagnostic. Submitted by hand, the API
says why:

| Spans submitted | Result |
|---|---|
| As emitted | `EvaluationInput has spans from more than one session, please submit each session separately` |
| Same spans, `session.id` added to every span | `ToolSelectionAccuracy` = 1.0 |

Fix: O5. Until then, check tool choice before release with WSO2 Integrator's Tool Trajectory
evaluation ([PARITY.md](PARITY.md) §3.8). No issue filed yet.

### E4. No client for on-demand and batch evaluation or datasets 🔧 (possible, not built)

Python's SDK includes on-demand and batch evaluation runners, a dataset client and custom
code-based evaluators. Ballerina has none. The APIs can be called the same way as I1 (signed
HTTP), or from the AWS CLI. WSO2 Integrator's evalsets are a separate format and are not
sent to AgentCore. No issue filed yet.

---

## Issues to file

Gaps above with no issue yet, in suggested order:

1. O5: baggage and `session.id` on every span (blocks E3).
2. O1: SigV4 signing in `ballerina/otel`.
3. E1 and E2: a recognised scope name and the OpenTelemetry GenAI attribute names in
   `ballerina/otel` and `ai.observe`.
4. O4: honour `OTEL_RESOURCE_ATTRIBUTES`.
5. I2: a per-request token provider for `ai:McpToolKit` and `mcp:StreamableHttpClient`, and
   headers on `notifications/initialized`.
6. O6: continue the incoming trace (after confirming which header AgentCore sends).

## Filed issues

| Issue | Title | State |
|---|---|---|
| [#2850](https://github.com/wso2/product-integrator/issues/2850) | Support AgentCore Identity as a token source for AI agents | open |
| [#2835](https://github.com/wso2/product-integrator/issues/2835) | Upgrade ai.aws.dynamodb to aws.dynamodb 3.x to support IAM role and default credentials | open |
| [#2823](https://github.com/wso2/product-integrator/issues/2823) | ai:McpToolKit cannot send custom HTTP headers to the MCP server | closed (workaround accepted) |
| [#2822](https://github.com/wso2/product-integrator/issues/2822) | ballerina/otel provides no way to flush pending spans and metrics before the program stops | open |
| [#2818](https://github.com/wso2/product-integrator/issues/2818) | Support non-string span attribute values in ballerina/observe | open |
| [#2597](https://github.com/wso2/product-integrator/issues/2597) | `ai:Agent` ignores the checkpoint methods of a custom `ai:Memory` | open |
| [#2573](https://github.com/wso2/product-integrator/issues/2573) | Anthropic model provider cannot authenticate with gateways that require `Authorization: Bearer` | open |
| [aws/agentcore-cli#1270](https://github.com/aws/agentcore-cli/issues/1270) | Enable OTLP collector sidecar for non-Python agents (.NET, Java, TypeScript) in AgentCore Runtime (AWS side, not filed by us) | open |

---

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First version: identity, governance, observability and evaluations gaps, with library code, workarounds and issue links |
