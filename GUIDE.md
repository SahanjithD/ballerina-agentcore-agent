# Deploying a Ballerina agent and MCP server on Amazon Bedrock AgentCore

This guide takes an empty AWS account to a working setup:
- a Ballerina AI agent on AgentCore Runtime;
- a Ballerina MCP server on AgentCore Runtime;
- a Ballerina REST API on Lambda;
- all of them behind one AgentCore Gateway, with policies, guardrails, tracing and
  evaluations switched on.

Every file, IAM policy and command you need is in this document. You should not need to
look anything up elsewhere.

**Status marks:**
- ✅ means the step ran on a live deployment (`us-east-1`, September 2026).
- ⚠️ means the step is written but has not been run end to end yet. Each one says what is
  missing.

**Versions:** Ballerina 2201.13.5, `ballerina/ai` 1.15.0, `ballerinax/ai.openai` 1.4.1,
`ballerina/mcp` 1.2.0, `ballerina/otel` 0.9.0, `ballerinax/aws` 1.0.2, OpenTelemetry
Collector contrib (latest), AWS CLI v2.

**Placeholders** used throughout:

| Placeholder | Meaning | Example |
|---|---|---|
| `<ACCOUNT>` | AWS account id | `123456789012` |
| `<REGION>` | AWS Region | `us-east-1` |
| `<GATEWAY_ID>` | Gateway id, from the console or `list-gateways` | `my-gateway-abc123` |
| `<GATEWAY_ROLE>` | Gateway's IAM role name | `AmazonBedrockAgentCoreGatewayDefaultServiceRole...` |
| `<ENGINE_ID>` | Policy engine id | `my_policies-a1b2c3d4e5` |
| `<MCP_RUNTIME_ID>`, `<AGENT_RUNTIME_ID>` | Runtime ids returned by `create-agent-runtime` | `ballerina_mcp_server-AbC123` |

Why each workaround exists is explained in more depth in
[BALLERINA-ON-AGENTCORE.md](BALLERINA-ON-AGENTCORE.md). This guide only says what to do.

---

## Contents

1. [What you will build](#1-what-you-will-build)
2. [Before you start](#2-before-you-start)
3. [Names, and the rules they must follow](#3-names-and-the-rules-they-must-follow)
4. [Rules for every container image](#4-rules-for-every-container-image)
5. [IAM: every role and permission](#5-iam-every-role-and-permission)
6. [The MCP server on AgentCore Runtime](#6-the-mcp-server-on-agentcore-runtime)
7. [The REST API on Lambda](#7-the-rest-api-on-lambda)
8. [The Gateway: inbound auth, tool targets and the model target](#8-the-gateway-inbound-auth-tool-targets-and-the-model-target)
9. [The agent on AgentCore Runtime](#9-the-agent-on-agentcore-runtime)
10. [Policy: access rules and guardrails](#10-policy-access-rules-and-guardrails)
11. [Observability](#11-observability)
12. [Evaluation](#12-evaluation)
13. [Identity: the agent's token from AgentCore Identity](#13-identity-the-agents-token-from-agentcore-identity)
14. [Changing things after deployment](#14-changing-things-after-deployment)
15. [Troubleshooting](#15-troubleshooting)
16. [What does not work yet](#16-what-does-not-work-yet)

---

## 1. What you will build

```
   caller (AWS CLI, app)
          │  SigV4 (IAM)
          ▼
  ┌──────────────────────────┐
  │ Agent  (AgentCore Runtime, HTTP protocol, :8080)
  │  ballerina/ai agent       │  local tools: sum, multiply, whereAmIRunning
  │  + OTel Collector process │──► CloudWatch (X-Ray OTLP, SigV4)
  └────────────┬─────────────┘
               │  Authorization: Bearer <Cognito token>
               ▼
  ┌──────────────────────────┐
  │ AgentCore Gateway        │  Cognito JWT inbound auth
  │  Policy engine (Cedar)   │  every call checked and recorded
  └──┬──────────┬──────────┬─┘
     │ SigV4    │ SigV4    │ API key from the token vault
     ▼          ▼          ▼
  MCP server  REST API    OpenAI
  (AgentCore  (Lambda +   (inference target:
   Runtime,    Function    the agent's model calls)
   MCP, :8000) URL)
```

| Piece | Hosted on | Tools it provides | Gateway target name |
|---|---|---|---|
| MCP server ([tools/mcp-server/](tools/mcp-server/)) | AgentCore Runtime, protocol `MCP` | `countWords`, `whoAmI` | `ballerinaMcpServer` |
| REST API ([tools/rest-api/](tools/rest-api/)) | Lambda container image + Function URL | `greetPerson`, `generateUuids` | `ballerinaRestApi` |
| Model | OpenAI, through the Gateway | (model calls) | `openai` |
| Agent (repo root) | AgentCore Runtime, protocol `HTTP` | local `sum`, `multiply`, `whereAmIRunning` | (caller of the Gateway) |

**Order of work:**
1. The tools (sections 6 and 7).
2. The Gateway and its targets (section 8).
3. The agent (section 9).
4. Policies (section 10).
5. Observability and evaluation (sections 11 and 12).

The agent goes after the Gateway because it reads the Gateway's tool list when it starts.

---

## 2. Before you start

### 2.1 Tools on your machine

- Ballerina **2201.13.5** (`bal version`)
- Docker with `buildx`, able to build `linux/arm64`. Apple Silicon does this natively.
- AWS CLI v2, configured for the target account
- Python 3 (used in a few one-liners)
- An OpenAI API key, for the model target

### 2.2 Account-level switches (once per account and Region)

1. **CloudWatch Transaction Search.** In the console: CloudWatch → Application Signals
   (APM) → Transaction Search → **Enable**, and choose *ingest spans as structured logs*.
   Spans then land in the `aws/spans` log group. ✅
2. **Index every trace while you test.** The default rule indexes 1%, so a handful of
   test calls index nothing. ✅

   ```bash
   aws xray update-indexing-rule --region <REGION> --name "Default" \
     --rule '{"Probabilistic": {"DesiredSamplingPercentage": 100}}'
   ```

3. **Region support.** Guardrails in policy are available only in some Regions,
   including `us-east-1`, `us-east-2`, `us-west-2`, `ap-southeast-2`, `ap-northeast-1`
   and `eu-west-2`. Check the AgentCore docs before choosing another Region.

### 2.3 Your own IAM permissions (the person deploying)

The simplest setup is:
- the AWS managed policy **`BedrockAgentCoreFullAccess`**;
- IAM role creation and `iam:PassRole` for the roles in section 5;
- ECR push, Lambda create/update, and Cognito read access.

Two permissions trip people up even with broad access:

| Permission | Why you need it |
|---|---|
| `bedrock-agentcore:InvokeGateway` on the Gateway ARN | `CreatePolicy` validates the policy by calling the Gateway as **you**. Without this, the policy ends in `CREATE_FAILED` with `Insufficient permissions to call gateway`. |
| `bedrock-agentcore:InvokeAgentRuntimeForUser` on the agent runtime ARN | Needed to invoke with `--runtime-user-id`, which is what makes the Runtime hand the agent a workload access token (section 13). |

A narrower policy for someone who only manages policies on one engine (✅ used in this
project):

```json
{
  "Sid": "ManageAgentCorePolicies",
  "Effect": "Allow",
  "Action": [
    "bedrock-agentcore:CreatePolicy",
    "bedrock-agentcore:ListPolicies",
    "bedrock-agentcore:GetPolicy",
    "bedrock-agentcore:UpdatePolicy",
    "bedrock-agentcore:DeletePolicy"
  ],
  "Resource": [
    "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:policy-engine/<ENGINE_ID>",
    "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:policy-engine/<ENGINE_ID>/policy/*"
  ]
}
```

---

## 3. Names, and the rules they must follow

Pick the names first. Two of these rules fail silently, and the target-name rule is the
expensive one.

| What | Allowed | Use | Why it matters |
|---|---|---|---|
| Runtime name | `[a-zA-Z][a-zA-Z0-9_]{0,47}`: letters, digits, underscores; **no hyphens** | `ballerina_agent`, `ballerina_mcp_server` | Rejected at create time |
| Gateway target name | `([0-9a-zA-Z][-]?){1,100}`: letters, digits, hyphens; **no underscores** | **camelCase with no hyphens**: `ballerinaMcpServer`, `ballerinaRestApi`, `openai` | A hyphen in **any** target name breaks Cedar schema generation for the **whole** Gateway. Every `CreatePolicy` then fails with *"Policy references an action that does not exist on the target gateway"*, and nothing is logged. ✅ found and fixed |
| Tool action in policies | `<target>___<tool>` (three underscores) | `ballerinaMcpServer___whoAmI` | Policies name tools this way |
| Model-call action | `<target>___POST:/v1/chat/completions` | `openai___POST:/v1/chat/completions` | No `/inference` prefix. It uses the target's **name**, even if you later change its connector |
| Lambda function name | Letters, digits, hyphens, underscores | `ballerina-tools-rest-api` | |

**Renaming a target later is destructive.**
- Saving a new name in the console deleted the target and then failed to recreate it.
- Every policy naming the old tools must be updated or deleted. Stale policies turn off
  tool-list filtering (section 10.6).

---

## 4. Rules for every container image

| Rule | What happens if you skip it |
|---|---|
| Build `--platform linux/arm64` | AgentCore Runtime runs nothing else and rejects the image with an unhelpful error. The Lambda must also be created `arm64` |
| Build `--provenance=false` | `buildx` pushes an attestation manifest list. The push succeeds, then AgentCore fails at deploy and Lambda says `image manifest ... not supported` |
| Never copy your local `Config.toml` into an image | It holds secrets for local runs. Each image instead copies a non-secret `observability.toml` **as** `/app/Config.toml` |
| `Config.toml` is strict | An unknown key is **fatal**. `[ballerinai.otel]` instead of `[ballerina.otel]` put the MCP server in a crash loop, and the only symptom at the caller was a 408. Run every image locally once |
| Configurables from the environment use `BAL_CONFIG_VAR_` + the name **uppercased** | `mcpClientSecret` → `BAL_CONFIG_VAR_MCPCLIENTSECRET`. The exact-case spelling is silently ignored |

Log in to ECR once per shell:

```bash
aws ecr get-login-password --region <REGION> \
  | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com

# One repository per image (or one repository with several tags):
aws ecr create-repository --region <REGION> --repository-name ballerina-agent
aws ecr create-repository --region <REGION> --repository-name ballerina-tools-mcp
aws ecr create-repository --region <REGION> --repository-name ballerina-tools-rest-api
```

---

## 5. IAM: every role and permission

Five identities are involved. This section has every JSON. Later sections only say when
to apply each one.

| Identity | Assumed by | Section |
|---|---|---|
| MCP server runtime role | AgentCore Runtime, running the MCP server | 5.1 |
| Agent runtime role | AgentCore Runtime, running the agent | 5.2 |
| Lambda role | Lambda, running the REST API | 5.3 |
| Gateway role | The Gateway, calling targets, the model, policies and guardrails | 5.4 |
| Lambda resource policy | Lets the Gateway role call the Function URL | 5.5 |

### 5.1 Runtime trust policy (both runtime roles)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AssumeRolePolicy",
    "Effect": "Allow",
    "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "<ACCOUNT>" },
      "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:*" }
    }
  }]
}
```

### 5.2 Runtime permissions (both runtime roles) ✅

This is AWS's recommended runtime policy, without Bedrock model access, since no model
is called through Bedrock. Replace `<RUNTIME_NAME>` with `ballerina_mcp_server` for one
role and `ballerina_agent` for the other. The repo copy is
[deploy/execution-policy.json](deploy/execution-policy.json).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ECRImageAccess", "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": ["arn:aws:ecr:<REGION>:<ACCOUNT>:repository/*"] },
    { "Sid": "ECRTokenAccess", "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Sid": "LogGroupManagement", "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:CreateLogGroup"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/*"] },
    { "Sid": "LogResourcePolicy", "Effect": "Allow",
      "Action": ["logs:PutResourcePolicy"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/<RUNTIME_NAME>-*"] },
    { "Sid": "LogGroupDiscovery", "Effect": "Allow",
      "Action": ["logs:DescribeLogGroups"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:*"] },
    { "Sid": "LogWrite", "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"] },
    { "Sid": "Tracing", "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"],
      "Resource": ["*"] },
    { "Sid": "Metrics", "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData", "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } } },
    { "Sid": "GetAgentAccessToken", "Effect": "Allow",
      "Action": ["bedrock-agentcore:GetWorkloadAccessToken",
                 "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
                 "bedrock-agentcore:GetWorkloadAccessTokenForUserId"],
      "Resource": ["arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default/workload-identity/<RUNTIME_NAME>-*"] }
  ]
}
```

Traces reached CloudWatch with exactly this policy. If the collector's log shows an
`AccessDenied` from `xray.<REGION>.amazonaws.com/v1/traces`, add `xray:PutSpans` and
`xray:PutSpansForIndexing` to the `Tracing` statement.

**Agent role only, for section 13** ⚠️ (written, not yet run). This lets the agent fetch
its Gateway token from AgentCore Identity instead of holding a client secret:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "GatewayTokenFromIdentity", "Effect": "Allow",
      "Action": "bedrock-agentcore:GetResourceOauth2Token",
      "Resource": ["arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default/workload-identity/*",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:token-vault/default",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:token-vault/default/oauth2credentialprovider/gateway-cognito"] },
    { "Sid": "GatewayTokenSecret", "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:bedrock-agentcore-identity!default/oauth2/gateway-cognito*" }
  ]
}
```

Create both roles:

```bash
aws iam create-role --role-name BedrockAgentCoreRuntime-ballerina_mcp_server \
  --assume-role-policy-document file://runtime-trust.json
aws iam put-role-policy --role-name BedrockAgentCoreRuntime-ballerina_mcp_server \
  --policy-name AgentCoreRuntimeExecution --policy-document file://runtime-mcp.json

aws iam create-role --role-name BedrockAgentCoreRuntime-ballerina_agent \
  --assume-role-policy-document file://runtime-trust.json
aws iam put-role-policy --role-name BedrockAgentCoreRuntime-ballerina_agent \
  --policy-name AgentCoreRuntimeExecution --policy-document file://runtime-agent.json
```

### 5.3 Lambda role (REST API) ✅

Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
aws iam create-role --role-name LambdaExecution-ballerina-tools-rest-api \
  --assume-role-policy-document file://lambda-trust.json
# Logs only: the service calls nothing else.
aws iam attach-role-policy --role-name LambdaExecution-ballerina-tools-rest-api \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### 5.4 Gateway role

The console creates this role when you create the Gateway (section 8.1). Find its name:

```bash
aws bedrock-agentcore-control get-gateway --region <REGION> \
  --gateway-identifier <GATEWAY_ID> --query roleArn --output text
```

Add this inline policy to it as the targets come up. Each statement fails on its own, so
missing any one of them breaks exactly one feature:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "InvokeMcpRuntime", "Effect": "Allow",
      "Action": "bedrock-agentcore:InvokeAgentRuntime",
      "Resource": ["arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:runtime/<MCP_RUNTIME_ID>",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:runtime/<MCP_RUNTIME_ID>/*"] },
    { "Sid": "InvokeRestFunctionUrl", "Effect": "Allow",
      "Action": "lambda:InvokeFunctionUrl",
      "Resource": "arn:aws:lambda:<REGION>:<ACCOUNT>:function:ballerina-tools-rest-api" },
    { "Sid": "ReadInferenceApiKey", "Effect": "Allow",
      "Action": "bedrock-agentcore:GetResourceApiKey",
      "Resource": ["arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:token-vault/default",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:token-vault/default/apikeycredentialprovider/openai-key"] },
    { "Sid": "ReadInferenceApiKeySecret", "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:bedrock-agentcore-identity!default/apikey/openai-key-*" },
    { "Sid": "PolicyEngineConfiguration", "Effect": "Allow",
      "Action": "bedrock-agentcore:GetPolicyEngine",
      "Resource": "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:policy-engine/<ENGINE_ID>" },
    { "Sid": "PolicyEngineAuthorization", "Effect": "Allow",
      "Action": ["bedrock-agentcore:AuthorizeAction", "bedrock-agentcore:PartiallyAuthorizeActions"],
      "Resource": ["arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:policy-engine/<ENGINE_ID>",
                   "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:gateway/<GATEWAY_ID>"] },
    { "Sid": "GuardrailsInPolicy", "Effect": "Allow",
      "Action": "bedrock:InvokeGuardrailChecks", "Resource": "*" }
  ]
}
```

| Statement | Needed for | What a missing grant looks like |
|---|---|---|
| `InvokeMcpRuntime` | MCP server target. **Keep the `/*` entry**: `?qualifier=DEFAULT` addresses a sub-resource | Target creation fails with an authorization error ✅ |
| `InvokeRestFunctionUrl` | REST target (also needs 5.5) | Tool call returns 403 ✅ |
| `ReadInferenceApiKey` + `ReadInferenceApiKeySecret` | Model target. Two grants, each fails on its own | Agent gets HTTP 400 `Failed to fetch outbound api key ... not authorized to perform: bedrock-agentcore:GetResourceApiKey`, then the same for `secretsmanager:GetSecretValue` ✅ |
| `PolicyEngine*` | Policy engine. The console may add these when you attach an engine. Add them if they are missing | `InternalServerException - Policy evaluation failed`, everything denied (AWS docs) |
| `GuardrailsInPolicy` | `when guardrails` policies | Guardrail policies fail to evaluate (AWS docs) |

Copy the exact secret ARN from the credential provider's page in the console, or from the
error message.

```bash
aws iam put-role-policy --role-name <GATEWAY_ROLE> \
  --policy-name BallerinaTargets --policy-document file://gateway-grants.json
```

### 5.5 Lambda resource policy for the Function URL ✅

A permission on the role alone does not authorise a Function URL call. The function also
needs a resource policy that names the Gateway role and carries the
`lambda:FunctionUrlAuthType` condition. **Use the CLI.** The console form can write an
empty `"Principal": {}`, or omit the condition, and both return 403 while looking
correct.

```bash
GW_ROLE_ARN=$(aws iam get-role --role-name <GATEWAY_ROLE> --query Role.Arn --output text)
aws lambda add-permission --region <REGION> --function-name ballerina-tools-rest-api \
  --statement-id AllowAgentCoreGateway --action lambda:InvokeFunctionUrl \
  --principal "$GW_ROLE_ARN" --function-url-auth-type AWS_IAM
```

---

## 6. The MCP server on AgentCore Runtime

AgentCore Runtime hosts MCP servers natively. Set the protocol to `MCP`, and the
container must serve streamable HTTP on `0.0.0.0:8000/mcp`. The server holds no secrets.

### 6.1 Files (`tools/mcp-server/`)

`Ballerina.toml`:

```toml
[package]
org = "dasun"
name = "tools_mcp_server"
version = "0.1.0"
distribution = "2201.13.5"

[build-options]
observabilityIncluded = true
```

`service.bal`:

```ballerina
import ballerina/log;
import ballerina/mcp;

// Side-effect import only: registers the `otel` tracing provider selected in Config.toml.
import ballerina/otel as _;
import ballerina/time;

// The MCP protocol contract fixes both the port and the path: 0.0.0.0:8000/mcp.
configurable int port = 8000;

listener mcp:StreamableHttpListener mcpListener = new (port);

# Proof of which server answered a tool call.
#
# + server - Name this server reports over MCP
# + language - Language and distribution the server is built on
# + hostedOn - Platform the server is running on
# + utcTime - Time the call was handled, in UTC
type ServerIdentity record {|
    string server;
    string language;
    string hostedOn;
    string utcTime;
|};

@mcp:StreamableHttpServiceConfig {
    info: {
        name: "Ballerina Tools",
        version: "0.1.0"
    },
    // The Gateway is the only client and does not carry a session across calls.
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Count the whitespace-separated words in a piece of text.
    #
    # + text - The text whose words should be counted
    # + return - The number of words found
    remote function countWords(string text) returns int {
        log:printInfo("tool called", tool = "countWords", chars = text.length());
        int count = 0;
        foreach string token in re `\s+`.split(text.trim()) {
            if token != "" {
                count += 1;
            }
        }
        return count;
    }

    # Identify the server that is handling this tool call. Use this to confirm which
    # backend a tool actually reached.
    #
    # + return - The server's name, language and hosting platform
    remote function whoAmI() returns ServerIdentity {
        log:printInfo("tool called", tool = "whoAmI");
        return {
            server: "Ballerina Tools",
            language: "Ballerina 2201.13.5 (Swan Lake Update 13)",
            hostedOn: "Amazon Bedrock AgentCore Runtime",
            utcTime: time:utcToString(time:utcNow())
        };
    }
}
```

The doc comments matter: they become the tool descriptions the model reads to choose a
tool.

`observability.toml` (copied into the image as `Config.toml`):

```toml
[ballerina.observe]
tracingEnabled = true
tracingProvider = "otel"

[ballerina.otel]
tracesEndpoint = "http://127.0.0.1:4317"
tracesProtocol = "grpc"

[ballerina.otel.tracesResourceAttributes]
# Fallback only; the collector replaces it with AgentCore's own identity.
"service.name" = "ballerina-mcp-server"

[ballerina.log]
format = "json"
```

`otel-collector.yaml`. `ballerina/otel` cannot SigV4-sign, and the X-Ray OTLP endpoint
accepts nothing else, so a collector runs beside the server and does the signing:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317          # loopback only

extensions:
  sigv4auth:
    region: <REGION>
    service: xray

exporters:
  otlp_http:
    traces_endpoint: https://xray.<REGION>.amazonaws.com/v1/traces
    auth:
      authenticator: sigv4auth
    compression: gzip

processors:
  filter/drop_health:                     # health probes every 2 s would become billable spans
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.url"] == "/ping"'

  resource/agent_identity:                # AgentCore's identity, parsed by start.sh
    attributes:
      - { key: service.name,                value: "${env:AGENT_SERVICE_NAME}",      action: upsert }
      - { key: cloud.resource_id,           value: "${env:AGENT_CLOUD_RESOURCE_ID}", action: upsert }
      - { key: deployment.environment.name, value: "${env:AGENT_DEPLOYMENT_ENV}",    action: upsert }
      - { key: aws.log.group.names,         value: "${env:AGENT_LOG_GROUP}",         action: upsert }
      - { key: aws.log.stream.names,        value: "${env:AGENT_LOG_STREAM}",        action: upsert }
      - { key: cloud.platform,              value: "${env:AGENT_CLOUD_PLATFORM}",    action: upsert }
      - { key: cloud.provider,              value: "${env:AGENT_CLOUD_PROVIDER}",    action: upsert }
      - { key: cloud.region,                value: "${env:AGENT_CLOUD_REGION}",      action: upsert }

  attributes/agentcore_origin:
    actions:
      - { key: aws.xray.origin,   value: "AWS::BedrockAgentCore::Runtime", action: upsert }
      - { key: aws.resource.type, value: "AWS::BedrockAgentCore::Runtime", action: upsert }
      - { key: aws.resource.arn,  value: "${env:AGENT_CLOUD_RESOURCE_ID}", action: upsert }

service:
  extensions: [sigv4auth]
  pipelines:
    traces:
      receivers: [otlp]
      # Keep on ONE line: start.sh removes processors with `sed 's|, <name>||'`.
      processors: [filter/drop_health, resource/agent_identity, attributes/agentcore_origin]
      exporters: [otlp_http]
```

`start.sh`. A runtime gives you one container, not a pod, so the collector runs as a
second process:

```sh
#!/bin/sh
set -e
CONFIG=/etc/otel/config.yaml

# AgentCore injects OTEL_RESOURCE_ATTRIBUTES with the identity CloudWatch expects.
otel_attr() {
    printf '%s' "$OTEL_RESOURCE_ATTRIBUTES" | tr ',' '\n' | sed -n "s/^$1=//p" | head -1
}
AGENT_SERVICE_NAME=$(otel_attr 'service\.name')
AGENT_CLOUD_RESOURCE_ID=$(otel_attr 'cloud\.resource_id')
AGENT_DEPLOYMENT_ENV=$(otel_attr 'deployment\.environment\.name')
AGENT_LOG_GROUP=$(otel_attr 'aws\.log\.group\.names')
AGENT_LOG_STREAM=$(otel_attr 'aws\.log\.stream\.names')
AGENT_CLOUD_PLATFORM=$(otel_attr 'cloud\.platform')
AGENT_CLOUD_PROVIDER=$(otel_attr 'cloud\.provider')
AGENT_CLOUD_REGION=$(otel_attr 'cloud\.region')
export AGENT_SERVICE_NAME AGENT_CLOUD_RESOURCE_ID AGENT_DEPLOYMENT_ENV \
    AGENT_LOG_GROUP AGENT_LOG_STREAM AGENT_CLOUD_PLATFORM AGENT_CLOUD_PROVIDER \
    AGENT_CLOUD_REGION

# An empty ${env:...} makes the collector exit, silently, since it runs in the
# background. Outside AgentCore (local runs), drop the identity processors instead.
if [ -z "$AGENT_SERVICE_NAME" ] || [ -z "$AGENT_CLOUD_RESOURCE_ID" ] ||
    [ -z "$AGENT_DEPLOYMENT_ENV" ] || [ -z "$AGENT_LOG_GROUP" ] ||
    [ -z "$AGENT_LOG_STREAM" ] || [ -z "$AGENT_CLOUD_PLATFORM" ] ||
    [ -z "$AGENT_CLOUD_PROVIDER" ] || [ -z "$AGENT_CLOUD_REGION" ]; then
    echo "start.sh: OTEL_RESOURCE_ATTRIBUTES missing or incomplete -- tracing without AgentCore resource identity" >&2
    sed -e 's|, resource/agent_identity||' -e 's|, attributes/agentcore_origin||' \
        "$CONFIG" > /tmp/otel-config.yaml
    CONFIG=/tmp/otel-config.yaml
fi

/usr/local/bin/otelcol --config="$CONFIG" &

# The server runs in the foreground, so the container lives and dies with it.
exec java -jar /app/mcp-server.jar
```

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/mcp-server
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/mcp-server/target/bin/tools_mcp_server.jar /app/mcp-server.jar
COPY --from=otel/opentelemetry-collector-contrib:latest /otelcol-contrib /usr/local/bin/otelcol
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/otelcol
EXPOSE 8000
ENTRYPOINT ["/app/start.sh"]
```

`.dockerignore`:

```
target/
generated/
Config.toml
```

Run `bal build` once locally to create `Dependencies.toml` before building the image.

### 6.2 Test locally

```bash
cd tools/mcp-server && bal run
# in another shell
curl -s -X POST http://localhost:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Also run the built image once (`docker run --rm -p 8000:8000 <image>`) to catch
`Config.toml` errors before AWS sees them.

### 6.3 Build, push, create the runtime ✅

```bash
cd tools/mcp-server
docker buildx build --provenance=false --platform linux/arm64 \
  -t <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-tools-mcp:latest --push .

cat > mcp-runtime.json <<'JSON'
{
  "agentRuntimeName": "ballerina_mcp_server",
  "agentRuntimeArtifact": {"containerConfiguration": {
    "containerUri": "<ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-tools-mcp:latest"}},
  "roleArn": "arn:aws:iam::<ACCOUNT>:role/BedrockAgentCoreRuntime-ballerina_mcp_server",
  "networkConfiguration": {"networkMode": "PUBLIC"},
  "protocolConfiguration": {"serverProtocol": "MCP"}
}
JSON
aws bedrock-agentcore-control create-agent-runtime --region <REGION> \
  --cli-input-json file://mcp-runtime.json
```

There is deliberately **no** `authorizerConfiguration`: inbound auth stays IAM, so the
Gateway's SigV4 signature is accepted.

**If you use the console instead,** expand every optional section. The console defaults
to:
- **protocol `HTTP`**: the container is probed on `:8080` and nothing reaches `:8000/mcp`.
  The runtime still shows `READY`, with an empty log group.
- **a new Cognito JWT authorizer**: the Gateway's SigV4 is then rejected forever as
  `Authorization error when sending message`, which looks exactly like a missing IAM
  grant.

Verify:

```bash
aws bedrock-agentcore-control get-agent-runtime --region <REGION> \
  --agent-runtime-id <MCP_RUNTIME_ID> \
  --query '{protocol:protocolConfiguration.serverProtocol,authorizer:authorizerConfiguration,status:status,arn:agentRuntimeArn}'
```

Expect `protocol: MCP`, `authorizer: null`, `status: READY`. In the console, also turn on
**Tracing** for the runtime (section 11).

The Gateway target endpoint is built from the runtime ARN, percent-encoded as one path
segment:

```bash
python3 -c "import urllib.parse,sys;print('https://bedrock-agentcore.<REGION>.amazonaws.com/runtimes/'+urllib.parse.quote(sys.argv[1],safe='')+'/invocations?qualifier=DEFAULT')" '<MCP_RUNTIME_ARN>'
```

---

## 7. The REST API on Lambda

AgentCore Runtime cannot host an ordinary REST API. Its HTTP contract mounts only
`/invocations`, so a path like `/v1/greet/{name}` has no route. A Lambda Function URL
gives a trusted HTTPS certificate with no domain or load balancer, and it verifies SigV4
natively, so the Gateway can call it as its own IAM role with no shared secret.

The **AWS Lambda Web Adapter** lets an unmodified `http:Listener` serve the Function URL.
It is copied in as an extension, so the Ballerina code has nothing Lambda-specific in it.

### 7.1 Files (`tools/rest-api/`)

`Ballerina.toml`:

```toml
[package]
org = "dasun"
name = "tools_rest_api"
version = "0.1.0"
distribution = "2201.13.5"

[build-options]
observabilityIncluded = true
```

`service.bal`:

```ballerina
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;

// The Lambda Web Adapter forwards to this port (its AWS_LWA_PORT).
configurable int port = 8080;

# A greeting rendered by this service.
#
# + message - The greeting text
# + servedBy - Which backend produced the greeting
# + utcTime - Time the greeting was produced, in UTC
type Greeting record {|
    string message;
    string servedBy;
    string utcTime;
|};

# A batch of freshly generated identifiers.
#
# + uuids - The generated UUIDs
# + count - How many were generated
type UuidBatch record {|
    string[] uuids;
    int count;
|};

# A rejected request.
#
# + message - Why the request was rejected
type ErrorMessage record {|
    string message;
|};

service /v1 on new http:Listener(port) {

    // The adapter's readiness probe; not exposed as a tool.
    resource function get health() returns json => {status: "ok"};

    resource function get greet/[string name]() returns Greeting {
        log:printInfo("request", operation = "greetPerson");
        return {
            message: string `Hello, ${name}!`,
            servedBy: "Ballerina REST API on AWS Lambda",
            utcTime: time:utcToString(time:utcNow())
        };
    }

    resource function get uuid(int count = 1) returns UuidBatch|http:BadRequest {
        log:printInfo("request", operation = "generateUuids", count = count);
        if count < 1 || count > 20 {
            return <http:BadRequest>{
                body: <ErrorMessage>{message: "count must be between 1 and 20"}
            };
        }
        string[] uuids = [];
        foreach int _ in 0 ..< count {
            uuids.push(uuid:createRandomUuid());
        }
        return {uuids, count};
    }
}
```

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/rest-api
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 /lambda-adapter /opt/extensions/lambda-adapter
ENV AWS_LWA_PORT=8080
ENV AWS_LWA_READINESS_CHECK_PATH=/v1/health
WORKDIR /app
COPY --from=build /home/ballerina/rest-api/target/bin/tools_rest_api.jar /app/rest-api.jar
ENTRYPOINT ["java", "-jar", "/app/rest-api.jar"]
```

`.dockerignore`: same as the MCP server's.

Test locally: `bal run`, then `curl localhost:8080/v1/greet/you`.

### 7.2 Build, push, create the function ✅

```bash
cd tools/rest-api
docker buildx build --provenance=false --platform linux/arm64 \
  -t <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-tools-rest-api:latest --push .

aws lambda create-function --region <REGION> --function-name ballerina-tools-rest-api \
  --package-type Image \
  --code ImageUri=<ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-tools-rest-api:latest \
  --role arn:aws:iam::<ACCOUNT>:role/LambdaExecution-ballerina-tools-rest-api \
  --architectures arm64 --timeout 60 --memory-size 1024
aws lambda wait function-active --region <REGION> --function-name ballerina-tools-rest-api

# AWS_IAM, not NONE: only SigV4-signed callers (the Gateway) get in.
aws lambda create-function-url-config --region <REGION> \
  --function-name ballerina-tools-rest-api --auth-type AWS_IAM
aws lambda get-function-url-config --region <REGION> \
  --function-name ballerina-tools-rest-api --query FunctionUrl --output text
```

The default 3-second timeout is shorter than a JVM cold start, which is why the command
sets 60 seconds and 1024 MB.

Then apply the resource policy from **5.5**.

### 7.3 The OpenAPI spec the Gateway reads

The Gateway turns each operation into a tool. Save this as
`gateway/tools-api-openapi.yaml`, with your Function URL host in `servers`:

```yaml
openapi: 3.0.3
info:
  title: Ballerina Tools API
  description: >-
    A small Ballerina REST service hosted on AWS Lambda behind a Function URL,
    exposed to agents as MCP tools by AgentCore Gateway.
  version: "1.0.0"
servers:
  - url: https://<FUNCTION_URL_HOST>/v1
paths:
  /greet/{name}:
    get:
      operationId: greetPerson
      summary: Generate a greeting for a named person
      description: >-
        Returns a greeting addressed to the given name, along with which backend
        produced it and the time it was produced. Use this to confirm that a call
        reached the Ballerina REST API rather than some other tool.
      parameters:
        - name: name
          in: path
          required: true
          description: The name of the person to greet.
          schema:
            type: string
      responses:
        "200":
          description: The greeting.
          content:
            application/json:
              schema:
                type: object
                properties:
                  message: { type: string }
                  servedBy: { type: string }
                  utcTime: { type: string }
  /uuid:
    get:
      operationId: generateUuids
      summary: Generate one or more random UUIDs
      description: >-
        Returns freshly generated random UUID version 4 strings. Use this whenever
        the user asks for a UUID, a GUID or a random unique identifier.
      parameters:
        - name: count
          in: query
          required: false
          description: How many UUIDs to generate, from 1 to 20. Defaults to 1.
          schema:
            type: integer
            default: 1
      responses:
        "200":
          description: The generated identifiers.
          content:
            application/json:
              schema:
                type: object
                properties:
                  uuids: { type: array, items: { type: string } }
                  count: { type: integer }
        "400":
          description: count was outside the range 1 to 20.
          content:
            application/json:
              schema:
                type: object
                properties:
                  message: { type: string }
```

If you generate a spec with `bal openapi -i service.bal`, edit it as follows before
giving it to the Gateway:
- **`servers`:** must be a static, fully qualified URL. The generated `{server}:{port}`
  template is rejected.
- **`operationId`:** this becomes the tool name, and the generated `getGreetName` makes a
  poor one.
- **`summary` and `description`:** add them to every operation. They are what the model
  reads to pick a tool, and `bal openapi` doesn't emit them.
- **Paths:** remove any that shouldn't be tools, such as `/health`.
- **Schemas:** keep them flat. `oneOf`, `anyOf` and `allOf` are not supported.

---

## 8. The Gateway: inbound auth, tool targets and the model target

### 8.1 Create the Gateway with Cognito inbound auth (console) ✅

AgentCore → Gateways → **Create gateway**:

| Field | Value |
|---|---|
| Name | your choice |
| Inbound auth | **Quick create with Cognito** (a `CUSTOM_JWT` authorizer). This creates a user pool, an app client for the client-credentials flow, and a resource server |
| Service role | Let the console create it. This is `<GATEWAY_ROLE>` in section 5.4 |
| Tracing | Turn it on once the Gateway exists (section 11) |

Note these for the agent:

| Value | Where to find it |
|---|---|
| Gateway MCP URL | `https://<GATEWAY_ID>.gateway.bedrock-agentcore.<REGION>.amazonaws.com/mcp` |
| Gateway model URL | `https://<GATEWAY_ID>.gateway.bedrock-agentcore.<REGION>.amazonaws.com/inference/v1` |
| Token URL | Cognito → User pools → the pool the Gateway created → **Domain**, plus `/oauth2/token` |
| Client id | Cognito → the pool → App clients |
| Client secret | Same app client. **Never paste it into chat or a file in the repo** |

Don't request a scope when minting tokens. Quick create truncates the resource-server id
to 22 characters and joins the scope with `:`, giving
`<truncated-id>/genesis-gateway:invoke`. Requesting the scope you'd expect returns
`invalid_scope`. With no scope requested, Cognito grants everything the client is
allowed. ✅

The Gateway's inbound authorizer reads **only** `Authorization: Bearer`. A token in
`x-api-key` gets `401 Missing Bearer token`. ✅

### 8.2 Target: the MCP server ✅

Gateway → Targets → **Add target**:

| Field | Value |
|---|---|
| Name | `ballerinaMcpServer` (camelCase, see section 3) |
| Type | MCP target, **do not use passthrough**, target type **MCP server** |
| Endpoint | The URL from 6.3 |
| Listing mode | Default |
| Outbound auth | **IAM role**, service `bedrock-agentcore`, Region `<REGION>` |

Apply the `InvokeMcpRuntime` statement from 5.4 **first**. Creating the target runs
`tools/list` against your server immediately, so it succeeds or fails on the spot.

The same as a CLI request:

```json
{
  "gatewayIdentifier": "<GATEWAY_ID>",
  "name": "ballerinaMcpServer",
  "targetConfiguration": {"mcp": {"mcpServer": {
    "endpoint": "<ENDPOINT_FROM_6.3>", "listingMode": "DEFAULT"}}},
  "credentialProviderConfigurations": [{
    "credentialProviderType": "GATEWAY_IAM_ROLE",
    "credentialProvider": {"iamCredentialProvider": {"service": "bedrock-agentcore", "region": "<REGION>"}}}]
}
```

```bash
aws bedrock-agentcore-control create-gateway-target --region <REGION> --cli-input-json file://mcp-target.json
```

### 8.3 Target: the REST API ✅

| Field | Value |
|---|---|
| Name | `ballerinaRestApi` |
| Type | MCP target, **do not use passthrough**, target type **REST API** |
| Schema | Paste `gateway/tools-api-openapi.yaml` from 7.3 |
| Outbound auth | **IAM role**, service `lambda`, Region `<REGION>` |

As a CLI request, the spec goes in as one string:

```bash
python3 - <<'PY' > rest-target.json
import json
print(json.dumps({
  "gatewayIdentifier": "<GATEWAY_ID>",
  "name": "ballerinaRestApi",
  "targetConfiguration": {"mcp": {"openApiSchema": {"inlinePayload": open("gateway/tools-api-openapi.yaml").read()}}},
  "credentialProviderConfigurations": [{
    "credentialProviderType": "GATEWAY_IAM_ROLE",
    "credentialProvider": {"iamCredentialProvider": {"service": "lambda", "region": "<REGION>"}}}]}))
PY
aws bedrock-agentcore-control create-gateway-target --region <REGION> --cli-input-json file://rest-target.json
```

This target does **no** connectivity check. It reports Ready from the spec alone, and
problems only show up on the first tool call.

### 8.4 Target: the model (OpenAI inference) ✅

Routing the agent's model calls through the Gateway does two things:
- the model conversation falls under the same policies as tool calls;
- the OpenAI key lives in the Gateway's token vault, so the agent holds no provider key.

1. **AgentCore → Identity → Outbound Auth → Add → API key.** Name it `openai-key` and
   paste the OpenAI key.
2. **Gateway → Targets → Add target → Inference.** Set the name to `openai`, the
   connector to **OpenAI**, and the credential provider to `openai-key`. Wait for
   `READY`. An invalid key puts the target in `UPDATE_UNSUCCESSFUL` with
   `Failed to discover models ... HTTP 401`.
3. Apply `ReadInferenceApiKey` and `ReadInferenceApiKeySecret` from 5.4.

The policy action for chat calls is `openai___POST:/v1/chat/completions`. The live
deployment's target is called `anthropic`, because it was created with the Anthropic
connector and later switched to OpenAI. That is why the repo's policy files say
`anthropic___...`.

**Use OpenAI from Ballerina, not Anthropic.**
- `ballerinax/ai.openai` sends its key as `Authorization: Bearer`, so the Gateway token
  works as the "API key" with no workaround. ✅
- `ballerinax/ai.anthropic` 1.3.5 hardcodes `x-api-key`, which the Gateway rejects. If
  you must use Anthropic, the loopback forwarder in
  [BALLERINA-ON-AGENTCORE.md §1.3](BALLERINA-ON-AGENTCORE.md) works. ✅

### 8.5 Check the Gateway's tool list

Mint a token without printing the secret (it is read from Cognito straight into
Python):

```bash
umask 077
POOL=<USER_POOL_ID>; CLIENT=<CLIENT_ID>; TOKEN_URL=https://<COGNITO_DOMAIN>/oauth2/token
aws cognito-idp describe-user-pool-client --region <REGION> --user-pool-id $POOL --client-id $CLIENT \
  --query UserPoolClient.ClientSecret --output text \
| CLIENT=$CLIENT TOKEN_URL=$TOKEN_URL python3 -c '
import os, sys, json, urllib.request, urllib.parse
data = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": os.environ["CLIENT"],
                               "client_secret": sys.stdin.read().strip()}).encode()
req = urllib.request.Request(os.environ["TOKEN_URL"], data=data,
                             headers={"Content-Type": "application/x-www-form-urlencoded"})
print(json.load(urllib.request.urlopen(req))["access_token"], end="")' > .tok
```

```bash
curl -s -X POST "https://<GATEWAY_ID>.gateway.bedrock-agentcore.<REGION>.amazonaws.com/mcp" \
  -H "Authorization: Bearer $(cat .tok)" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
rm -f .tok   # when done
```

You should see `ballerinaMcpServer___countWords`, `ballerinaMcpServer___whoAmI`,
`ballerinaRestApi___greetPerson` and `ballerinaRestApi___generateUuids`, plus the
Gateway's own search tool if it's enabled.

Without the `MCP-Protocol-Version` header the Gateway answers
`Unsupported protocol version: 2025-03-26`. The versions it accepts are listed under the
Gateway's MCP protocol settings (`protocolConfiguration.mcp.supportedVersions`).
`ballerina/mcp` works with the defaults. ✅

---

## 9. The agent on AgentCore Runtime

### 9.1 The container contract

| Requirement | Value |
|---|---|
| Host and port | `0.0.0.0:8080` |
| Platform | `linux/arm64` |
| `GET /ping` | `200` with `{"status":"Healthy"}` |
| `POST /invocations` | JSON in, JSON out |
| Session header | `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id`, at least 33 characters |

Each session runs in its own micro VM, so one container serves one session.

### 9.2 Files (repo root)

`Ballerina.toml`:

```toml
[package]
org = "dasun"
name = "ballerina_agent"
version = "0.1.0"
distribution = "2201.13.5"

[build-options]
observabilityIncluded = true
```

`main.bal`:

```ballerina
import ballerina/log;

// Side-effect import only: registers the `otel` tracing provider that Config.toml selects.
import ballerina/otel as _;

// The Runtime contract is served by service.bal; main must not block.
public function main() {
    log:printInfo("ballerina agent starting", port = port);
}
```

`service.bal`:

```ballerina
import ballerina/ai;
import ballerina/http;
import ballerina/log;

// AgentCore Runtime probes and invokes the container over HTTP on port 8080.
configurable int port = 8080;

// Open record: tolerate extra fields in the caller's payload.
type InvocationRequest record {
    string prompt;
};

type InvocationResponse record {|
    string response;
    string status;
|};

type FailureResponse record {|
    string message;
    string status;
|};

service / on new http:Listener(port) {

    // Health probe polled by AgentCore Runtime.
    resource function get ping() returns json => {status: "Healthy"};

    // Primary agent invocation endpoint.
    resource function post invocations(@http:Payload InvocationRequest payload,
            @http:Header {name: "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"} string? sessionId,
            http:Headers headers)
            returns http:Ok|http:InternalServerError {

        // The session id doubles as the agent's memory key.
        string session = sessionId ?: "default";
        log:printInfo("invoking agent", session = session);

        // Presence only: the workload access token is a credential and must never be logged.
        log:printInfo("identity headers", session = session,
                workloadAccessToken = headers.hasHeader("WorkloadAccessToken"),
                userId = headers.hasHeader("X-Amzn-Bedrock-AgentCore-Runtime-User-Id"));

        string|http:HeaderNotFoundError workloadToken = headers.getHeader("WorkloadAccessToken");
        ai:Agent|error agent = agentFor(workloadToken is string ? workloadToken : ());
        if agent is error {
            log:printError("agent unavailable", agent, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: agent.message(), status: "error"}
            };
        }

        string|ai:Error response = agent.run(payload.prompt, sessionId = session);
        if response is ai:Error {
            log:printError("agent run failed", response, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: response.message(), status: "error"}
            };
        }

        return <http:Ok>{body: <InvocationResponse>{response, status: "success"}};
    }
}
```

`agents.bal`. The repo's copy has the live Gateway's URLs as defaults. Here they are
required, so a missing setting fails at startup instead of calling someone else's
Gateway:

```ballerina
import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/ai.openai;

configurable openai:OPEN_AI_MODEL_NAMES modelType = openai:GPT_4_1;

// The Gateway's model endpoint, ending in /v1: the provider posts to {inferenceUrl}/chat/completions.
configurable string inferenceUrl = ?;

// The Gateway's MCP endpoint.
configurable string mcpServerUrl = ?;

// Cognito client credentials for the Gateway (section 8.1). Not needed once section 13 is in place.
configurable string mcpTokenUrl = "";
configurable string mcpClientId = "";
configurable string mcpClientSecret = "";

// Fallback for MCP servers that take a long-lived static token instead.
configurable string mcpAuthToken = "";

@ai:AgentTool
isolated function sum(int a, int b) returns int => a + b;

@ai:AgentTool
isolated function multiply(int a, int b) returns int => a * b;

# Identity of the process that ran a tool call.
#
# + servedBy - Which process handled the call
# + language - Language and distribution it is built on
# + utcTime - Time the call was handled, in UTC
type AgentIdentity record {|
    string servedBy;
    string language;
    string utcTime;
|};

# Report which process actually ran this tool. A local `@ai:AgentTool` runs inside the
# agent itself; `ballerinaMcpServer___whoAmI` runs in a separate container behind the Gateway.
#
# + return - Identity of the agent process
@ai:AgentTool
isolated function whereAmIRunning() returns AgentIdentity => {
    servedBy: "ballerina-agent, in-process @ai:AgentTool",
    language: "Ballerina 2201.13.5 (Swan Lake Update 13)",
    utcTime: time:utcToString(time:utcNow())
};

# Mints a Gateway access token with the Cognito client credentials held in configuration.
#
# + return - A bearer token for the Gateway, or an error if the token endpoint refuses
isolated function mintGatewayToken() returns string|error {
    http:Client tokenClient = check new (mcpTokenUrl);
    http:Request request = new;
    request.setTextPayload(string `grant_type=client_credentials&client_id=${mcpClientId}` +
            string `&client_secret=${mcpClientSecret}`, "application/x-www-form-urlencoded");
    // Open record: Cognito returns expires_in and token_type alongside the token.
    record {string access_token;} token = check tokenClient->post("", request);
    return token.access_token;
}

# Picks where the Gateway token comes from: AgentCore Identity when configured and the
# Runtime passed a workload access token; otherwise a static token, then the client secret.
#
# + workloadToken - The invocation's `WorkloadAccessToken` header, if any
# + return - A Gateway bearer token and where it came from, or an error
isolated function gatewayToken(string? workloadToken) returns [string, string]|error {
    if gatewayCredentialProvider != "" && workloadToken is string {
        return [check gatewayTokenFromIdentity(workloadToken), "agentcore-identity"];
    }
    if mcpAuthToken != "" {
        return [mcpAuthToken, "static-token"];
    }
    if mcpClientSecret != "" {
        return [check mintGatewayToken(), "client-secret"];
    }
    return error("no Gateway credentials: invoke with a user id so the Runtime supplies a " +
            "workload access token, or configure a client secret");
}

# Builds the agent with a Gateway token.
#
# + token - A Gateway bearer token
# + return - The agent, or an error if the Gateway cannot be reached
isolated function buildAgent(string token) returns ai:Agent|error {
    // McpToolKit calls listTools in its init, so the (policy-filtered) tool list is fixed here.
    ai:McpToolKit gateway = check new (mcpServerUrl, auth = {token});

    // The OpenAI provider sends its key as Authorization: Bearer, which the Gateway reads.
    ai:ModelProvider model = check new openai:ModelProvider(token, modelType, inferenceUrl);

    return check new ai:Agent(
        systemPrompt = {
            role: "Assistant",
            instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
        }, memory = (), model = model, tools = [sum, multiply, whereAmIRunning, gateway]
    );
}

isolated ai:Agent? cachedAgent = ();

# Returns this container's agent, building it on first use. One container serves one
# session, so this is one agent per session.
#
# + workloadToken - The invocation's `WorkloadAccessToken` header, if any
# + return - The agent, or an error
isolated function agentFor(string? workloadToken) returns ai:Agent|error {
    lock {
        ai:Agent? existing = cachedAgent;
        if existing is ai:Agent {
            return existing;
        }
    }
    [string, string] [token, tokenSource] = check gatewayToken(workloadToken);
    log:printInfo("gateway token obtained", tokenSource = tokenSource);
    ai:Agent agent = check buildAgent(token);
    lock {
        cachedAgent = agent;
    }
    return agent;
}
```

`identity.bal`. This is only used when section 13 is configured. With
`gatewayCredentialProvider` left empty it is never called, but it must be present because
`agents.bal` refers to it:

```ballerina
import ballerina/http;
import ballerinax/aws;
import ballerinax/aws.auth;

// Name of the OAuth2 credential provider in AgentCore Identity holding the Gateway's
// Cognito client. Empty disables this path.
configurable string gatewayCredentialProvider = "";
configurable string awsRegion = "us-east-1";

final string identityHost = aws:resolveEndpointHost("bedrock-agentcore", awsRegion);
final http:Client identityClient = check new (aws:resolveEndpoint("bedrock-agentcore", awsRegion));

// The default credential chain resolves the runtime's execution role inside AgentCore.
final auth:CredentialProvider awsCredentials = check new (auth:DEFAULT_CREDENTIALS);

# Exchanges the Runtime's workload access token for a Gateway token (M2M flow).
#
# + workloadToken - The `WorkloadAccessToken` header from the current invocation
# + return - An access token for the Gateway, or an error
isolated function gatewayTokenFromIdentity(string workloadToken) returns string|error {
    string path = "/identities/oauth2/token";
    json requestBody = {
        resourceCredentialProviderName: gatewayCredentialProvider,
        scopes: [],
        oauth2Flow: "M2M",
        workloadIdentityToken: workloadToken
    };
    byte[] payload = requestBody.toJsonString().toBytes();
    map<string> signedHeaders = check auth:getSignedHeaders({
        method: "POST",
        host: identityHost,
        path,
        headers: {"content-type": "application/json"},
        payload
    }, check awsCredentials.getCredentials(), awsRegion, "bedrock-agentcore");

    // Open record: the response also carries sessionUri/sessionStatus for user flows.
    record {string accessToken?;} response =
            check identityClient->post(path, payload, signedHeaders, "application/json");
    string? accessToken = response.accessToken;
    if accessToken is () {
        return error("AgentCore Identity returned no access token for " + gatewayCredentialProvider);
    }
    return accessToken;
}
```

`observability.toml` (copied into the image as `Config.toml`):

```toml
[ballerina.observe]
tracingEnabled = true
tracingProvider = "otel"

[ballerina.otel]
tracesEndpoint = "http://127.0.0.1:4317"
tracesProtocol = "grpc"

[ballerina.otel.tracesResourceAttributes]
"service.name" = "ballerina-agent"

# JSON so CloudWatch parses each line; with tracing on, each line carries traceId/spanId.
[ballerina.log]
format = "json"
```

`otel-collector.yaml` for the agent. It has the MCP server's processors plus five that
make CloudWatch's GenAI dashboard and AgentCore Evaluations read Ballerina's spans. The
reason for each is in section 11.3.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317

extensions:
  sigv4auth:
    region: <REGION>
    service: xray

exporters:
  otlp_http:
    traces_endpoint: https://xray.<REGION>.amazonaws.com/v1/traces
    auth:
      authenticator: sigv4auth
    compression: gzip

processors:
  filter/drop_health:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.url"] == "/ping"'

  attributes/genai_token_types:
    actions:
      - { key: gen_ai.usage.input_tokens,  action: convert, converted_type: int }
      - { key: gen_ai.usage.output_tokens, action: convert, converted_type: int }

  transform/genai_total_tokens:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(span.attributes["gen_ai.usage.total_tokens"], Int(span.attributes["gen_ai.usage.input_tokens"]) + Int(span.attributes["gen_ai.usage.output_tokens"])) where span.attributes["gen_ai.usage.input_tokens"] != nil and span.attributes["gen_ai.usage.output_tokens"] != nil

  transform/scope_name:
    error_mode: ignore
    trace_statements:
      - context: scope
        statements:
          - set(scope.name, "opentelemetry.instrumentation.ballerina") where scope.name == "otel"

  transform/genai_eval_aliases:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(span.attributes["gen_ai.task.input"], span.attributes["gen_ai.input.messages"]) where span.attributes["gen_ai.operation.name"] == "invoke_agent" and span.attributes["gen_ai.input.messages"] != nil
          - set(span.attributes["gen_ai.task.output"], span.attributes["gen_ai.output.messages"]) where span.attributes["gen_ai.operation.name"] == "invoke_agent" and span.attributes["gen_ai.output.messages"] != nil
          - set(span.attributes["agentcore.invocation.user_prompt"], span.attributes["gen_ai.input.messages"]) where span.attributes["gen_ai.operation.name"] == "invoke_agent" and span.attributes["gen_ai.input.messages"] != nil
          - set(span.attributes["agentcore.invocation.agent_response"], span.attributes["gen_ai.output.messages"]) where span.attributes["gen_ai.operation.name"] == "invoke_agent" and span.attributes["gen_ai.output.messages"] != nil
          - set(span.attributes["gen_ai.tool.call.arguments"], span.attributes["gen_ai.tool.arguments"]) where span.attributes["gen_ai.operation.name"] == "execute_tool" and span.attributes["gen_ai.tool.arguments"] != nil
          - set(span.attributes["gen_ai.tool.call.result"], span.attributes["gen_ai.tool.output"]) where span.attributes["gen_ai.operation.name"] == "execute_tool" and span.attributes["gen_ai.tool.output"] != nil

  resource/agent_identity:
    attributes:
      - { key: service.name,                value: "${env:AGENT_SERVICE_NAME}",      action: upsert }
      - { key: cloud.resource_id,           value: "${env:AGENT_CLOUD_RESOURCE_ID}", action: upsert }
      - { key: deployment.environment.name, value: "${env:AGENT_DEPLOYMENT_ENV}",    action: upsert }
      - { key: aws.log.group.names,         value: "${env:AGENT_LOG_GROUP}",         action: upsert }
      - { key: aws.log.stream.names,        value: "${env:AGENT_LOG_STREAM}",        action: upsert }
      - { key: cloud.platform,              value: "${env:AGENT_CLOUD_PLATFORM}",    action: upsert }
      - { key: cloud.provider,              value: "${env:AGENT_CLOUD_PROVIDER}",    action: upsert }
      - { key: cloud.region,                value: "${env:AGENT_CLOUD_REGION}",      action: upsert }

  attributes/agentcore_origin:
    actions:
      - { key: aws.xray.origin,   value: "AWS::BedrockAgentCore::Runtime", action: upsert }
      - { key: aws.resource.type, value: "AWS::BedrockAgentCore::Runtime", action: upsert }
      - { key: aws.resource.arn,  value: "${env:AGENT_CLOUD_RESOURCE_ID}", action: upsert }

  attributes/session_id:
    actions:
      - { key: session.id, from_attribute: gen_ai.conversation.id, action: upsert }

service:
  extensions: [sigv4auth]
  pipelines:
    traces:
      receivers: [otlp]
      # Keep on ONE line: start.sh removes processors with `sed 's|, <name>||'`.
      processors: [filter/drop_health, attributes/genai_token_types, transform/genai_total_tokens, transform/scope_name, transform/genai_eval_aliases, resource/agent_identity, attributes/agentcore_origin, attributes/session_id]
      exporters: [otlp_http]
```

Use the **contrib** collector, not AWS's ADOT collector. ADOT v0.50.0 doesn't ship the
`transform` processor.

`start.sh`: identical to the MCP server's in 6.1, except for the last line:

```sh
exec java -jar /app/agent.jar
```

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/agent
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/agent/target/bin/ballerina_agent.jar /app/agent.jar
COPY --from=otel/opentelemetry-collector-contrib:latest /otelcol-contrib /usr/local/bin/otelcol
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/otelcol
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
```

`.dockerignore`:

```
target/
generated/
Config.toml
deploy/
*.md
.git/
tools/
gateway/
```

### 9.3 Test locally

Create a local `Config.toml` (git-ignored, never copied into the image) with the
Gateway values from 8.1, then:

```bash
bal run
curl localhost:8080/ping
curl -X POST localhost:8080/invocations -H 'Content-Type: application/json' \
  -H 'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: local-0000000000000000000000000000000' \
  -d '{"prompt":"Use the whoAmI tool, then add 2 and 3."}'
```

### 9.4 Build, push, create the runtime ✅

```bash
docker buildx build --provenance=false --platform linux/arm64 \
  -t <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-agent:latest --push .
```

The runtime takes its settings as environment variables. The client secret is read from
Cognito into a mode-0600 file, so it never appears on screen or in the process list:

```bash
umask 077
aws cognito-idp describe-user-pool-client --region <REGION> --user-pool-id <USER_POOL_ID> \
  --client-id <CLIENT_ID> --query UserPoolClient.ClientSecret --output text \
| python3 -c '
import json, sys
secret = sys.stdin.read().strip()
gw = "https://<GATEWAY_ID>.gateway.bedrock-agentcore.<REGION>.amazonaws.com"
print(json.dumps({
  "agentRuntimeName": "ballerina_agent",
  "agentRuntimeArtifact": {"containerConfiguration": {
    "containerUri": "<ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/ballerina-agent:latest"}},
  "roleArn": "arn:aws:iam::<ACCOUNT>:role/BedrockAgentCoreRuntime-ballerina_agent",
  "networkConfiguration": {"networkMode": "PUBLIC"},
  "protocolConfiguration": {"serverProtocol": "HTTP"},
  "environmentVariables": {
    "BAL_CONFIG_VAR_MCPSERVERURL": gw + "/mcp",
    "BAL_CONFIG_VAR_INFERENCEURL": gw + "/inference/v1",
    "BAL_CONFIG_VAR_MCPTOKENURL": "https://<COGNITO_DOMAIN>/oauth2/token",
    "BAL_CONFIG_VAR_MCPCLIENTID": "<CLIENT_ID>",
    "BAL_CONFIG_VAR_MCPCLIENTSECRET": secret}}))' > agent-runtime.json

aws bedrock-agentcore-control create-agent-runtime --region <REGION> \
  --cli-input-json file://agent-runtime.json
rm -f agent-runtime.json
```

Anyone with `bedrock-agentcore:GetAgentRuntime` can read the client secret in the
runtime's configuration. Section 13 removes it.

In the console, turn on **Tracing** for this runtime (section 11).

### 9.5 Invoke ✅

```bash
ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region <REGION> \
  --query "agentRuntimes[?agentRuntimeName=='ballerina_agent'].agentRuntimeArn | [0]" --output text)

aws bedrock-agentcore invoke-agent-runtime --region <REGION> \
  --agent-runtime-arn "$ARN" \
  --runtime-session-id "$(uuidgen)$(uuidgen)" \
  --content-type application/json --accept application/json \
  --cli-binary-format raw-in-base64-out \
  --payload '{"prompt":"Use whoAmI, greet Ada, generate 2 UUIDs, and add 2 and 3."}' \
  /dev/stdout
```

To continue a conversation, reuse the same session id. The id is also the agent's memory
key.

Logs:

```bash
aws logs tail /aws/bedrock-agentcore/runtimes/<AGENT_RUNTIME_ID>-DEFAULT --region <REGION> --follow
```

A `RuntimeClientError (500)` at the caller hides the real cause. The cause is in this
log, on the `agent run failed` or `agent unavailable` line. Gateway denials, IAM errors
and provider errors all show up there.

**Limit:** the OpenAI provider takes a fixed key, so the Gateway token can't be renewed
inside a session. Cognito tokens last one hour, so a session that lives longer starts
failing its model calls.

---

## 10. Policy: access rules and guardrails

The Gateway checks every tool call and model call against Cedar policies in a **policy
engine**. Under `ENFORCE` the default is **deny**. Ready-made, tested policy files are in
[policy/](policy/README.md).

### 10.1 Create the engine and attach it in LOG_ONLY ✅

```bash
aws bedrock-agentcore-control create-policy-engine --region <REGION> \
  --name ballerina_agent_policies --query policyEngineId --output text
```

Then attach it in the console: **Gateway → Policy → attach engine, mode `LOG_ONLY`.**
Make sure the Gateway role has the `PolicyEngine*` statements from 5.4.

In `LOG_ONLY` the engine records what it would decide and blocks nothing. Switch to
`ENFORCE` in the same place once the decisions look right (10.7).

### 10.2 How to create any policy ✅

| Policy kind | Definition key | Validation mode |
|---|---|---|
| Plain Cedar (`permit`/`forbid`, `when {}`) | `{"cedar": {"statement": "..."}}` | default for the broad baseline; `IGNORE_ALL_FINDINGS` for single-action rules |
| Guardrails (`when guardrails {}`) or `suppressOutput` | `{"policy": {"statement": "..."}}`. With `cedar` it fails with ``unexpected token `guardrails` `` | `IGNORE_ALL_FINDINGS` |

```bash
GW=arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:gateway/<GATEWAY_ID>
FILE=policy/permit-tool.cedar; KEY=cedar; NAME=permit_whoami

python3 - "$GW" "$FILE" "$KEY" > def.json <<'PY'
import json, sys
gw, path, key = sys.argv[1:]
print(json.dumps({key: {"statement": open(path).read().replace("GATEWAY_ARN_PLACEHOLDER", gw)}}))
PY

aws bedrock-agentcore-control create-policy --region <REGION> \
  --policy-engine-id <ENGINE_ID> --name "$NAME" \
  --enforcement-mode ACTIVE --validation-mode IGNORE_ALL_FINDINGS \
  --definition file://def.json --query policyId --output text

# CreatePolicy returns CREATING and validates afterwards. Check ~15 s later:
aws bedrock-agentcore-control get-policy --region <REGION> --policy-engine-id <ENGINE_ID> \
  --policy-id <POLICY_ID> --query '{status:status,reasons:statusReasons}'
```

Things to know about creating policies:
- **Policy names** use underscores, not hyphens.
- **A failed create keeps its name.** Retrying with the same name returns
  `ConflictException` until you delete the failed policy.
- **Semantic findings fail the create unless you skip them.** "Overly Permissive" (an
  action-scoped permit that allows any caller) and "Overly Restrictive" (a forbid on
  something nothing permits) both need `IGNORE_ALL_FINDINGS`. Action names are still
  validated in that mode.
- **The Gateway ARN must be written out in full.** Cedar doesn't accept a wildcard
  resource.

### 10.3 The policies, and what each one did ✅

Replace `GATEWAY_ARN_PLACEHOLDER` with your Gateway ARN (the snippet above does it), and
`anthropic` with your model target's name (`openai` if you followed 8.4).

**Baseline: allow everything on this Gateway.** Use it while moving to `ENFORCE`, then
replace it with specific permits.

```cedar
permit(
    principal,
    action,
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
```

**Allow one tool** (`cedar`, `IGNORE_ALL_FINDINGS`). With only this permit and the model
permit active, `tools/list` returned just this one tool out of 8, and an unpermitted
tool was refused with
`Tool call not allowed due to policy enforcement [No policy applies to the request (denied by default).]`.

```cedar
permit (
    principal,
    action == AgentCore::Action::"ballerinaMcpServer___whoAmI",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
```

**Allow model calls** (`cedar`, `IGNORE_ALL_FINDINGS`). Without this, `ENFORCE` denies
every model call and the agent cannot answer at all.

```cedar
permit (
    principal,
    action == AgentCore::Action::"openai___POST:/v1/chat/completions",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
```

The Responses API is a separate action, `openai___POST:/v1/responses`. Permit it as well
if you call it.

**Deny model calls: the off switch** (`cedar`, `IGNORE_ALL_FINDINGS`). The agent's next
model call failed with 403:
`Request Denied: Gateway Target request not allowed due to policy enforcement [Policy evaluation denied due to test_forbid_inference-...]`.
`forbid` overrides any `permit`.

```cedar
forbid (
    principal,
    action == AgentCore::Action::"openai___POST:/v1/chat/completions",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
```

**Deny a tool call by argument value** (`cedar`, `IGNORE_ALL_FINDINGS`). Calls with
`count > 5` were denied.

```cedar
forbid(
    principal,
    action == AgentCore::Action::"ballerinaRestApi___generateUuids",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when {
    // `count` is optional in the tool's schema, so test for it before reading it.
    context.input has count && context.input.count > 5
};
```

**Guardrail on tool input** (`policy`, `IGNORE_ALL_FINDINGS`).
`greetPerson(name="jane.doe@example.com")` was denied, and the Lambda was never
invoked:

```cedar
forbid (
    principal,
    action == AgentCore::Action::"ballerinaRestApi___greetPerson",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["EMAIL"], [context.input.name]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
```

**Guardrail on tool output** (`policy`, `IGNORE_ALL_FINDINGS`). For
`greetPerson(name="Jane Smith")` the tool ran, but the caller received
`Output blocked by policy: ...guardrail_greet_name_output...`:

```cedar
suppressOutput (
    principal,
    action == AgentCore::Action::"ballerinaRestApi___greetPerson",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["NAME"], [context.output.message]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
```

**Guardrail on a model call** (`policy`, `IGNORE_ALL_FINDINGS`). An email in the
Responses API's `instructions` returned 403. Without it, the request returned 200.

```cedar
forbid (
    principal,
    action == AgentCore::Action::"openai___POST:/v1/responses",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["EMAIL"], [context.input.instructions]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
```

**Prompt-attack check on a tool input** ⚠️ This saves and is accepted, but it has only
run in `LOG_ONLY`. Blocking has not been exercised.

```cedar
forbid (
    principal,
    action == AgentCore::Action::"ballerinaMcpServer___countWords",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::PromptAttack(["PROMPT_INJECTION"], [context.input.text])["PROMPT_INJECTION"]
        .confidenceScore
        .greaterThan(decimal("0.0"))
};
```

The `0.0` thresholds above were chosen to prove each rule blocks. For production, start
from AWS's defaults: 0.2 for sensitive information and content filters, 0.4 for prompt
attacks.

### 10.4 What guardrails in policy can and cannot see

- **Available checks:** `SensitiveInformation`, `ContentFilter` and `PromptAttack`
  only. Denied topics are not available.
- **Arguments must be plain string fields.**
  - For tools, that means a tool's own arguments and outputs.
  - For model calls, chat `messages` is a list of records, and the guardrail rejects it:
    *"argument `context.input.messages` has type `Set<record>` ... but the provider
    declares argument type `string`"*.
  - So the chat conversation itself cannot be screened by policy, for any client
    language. ✅ tested.
- **`when guardrails` cannot be combined with a plain `when {}`** in the same policy.

### 10.5 What a model-call rule can check

For `openai___POST:/v1/chat/completions`, a rule can test:
- `model`;
- `max_completion_tokens` and the other numeric options;
- whether `tools` is present or empty;
- the caller (`principal`).

A rule **cannot** test:
- **Which tools are offered**, or which tool the model called earlier. They sit inside
  lists of records, and Cedar can't look into each item.
- **Message text**, which is typed as an empty record.
- **The model's reply.** `context.output` is not allowed in plain Cedar.

So a tool defined inside the agent (`@ai:AgentTool`) can't be governed by policy.
To govern a tool:
- host it behind the Gateway (sections 6 and 7);
- or use a Gateway interceptor Lambda, which sees the raw request body (not yet tested
  here);
- or use `ai:RequiresApproval` on the tool in Ballerina.

### 10.6 Tool-list filtering

With `ENFORCE` on, `tools/list` returns only the tools the caller could be allowed to
call. The model never sees the rest. ✅

**Stale policies switch this off.** A policy naming an action that no longer exists, for
example after a target rename, makes `tools/list` return every tool again. Calls are
still enforced, but the model is shown tools it can't use. Delete or fix stale policies:

```bash
aws bedrock-agentcore-control list-policies --region <REGION> --policy-engine-id <ENGINE_ID> \
  --query 'policies[].{name:name,status:status,id:policyId}' --output table
```

### 10.7 Moving to ENFORCE safely

1. Attach in `LOG_ONLY` and create the baseline permit and your specific rules.
2. Exercise the agent, then read the decisions (11.4).
3. Switch to `ENFORCE` in the console.
4. Replace the baseline permit with specific permits, one at a time.

---

## 11. Observability

### 11.1 Switches

- **Account:** Transaction Search and the indexing rule (2.2).
- **Each runtime:** console → the runtime → **Tracing: enable**. Spans are captured from
  then on; nothing is backfilled.
- **The Gateway:** console → the Gateway → enable tracing (and log delivery, if you want
  the Gateway's own logs).

Runtime metrics (invocations, errors, latency, vCPU, memory) need no setup.

### 11.2 Where things land

| What | Where |
|---|---|
| Agent and MCP server logs (JSON, with `traceId`/`spanId`) | `/aws/bedrock-agentcore/runtimes/<RUNTIME_ID>-DEFAULT` |
| All spans: agent, MCP server, Gateway, policy decisions | `aws/spans` (Transaction Search) |
| GenAI dashboard: sessions, traces, tokens | CloudWatch → GenAI Observability → Bedrock AgentCore |

Dashboards lag 10–15 minutes. To check immediately:

```bash
aws logs tail aws/spans --region <REGION> --since 30m \
  | grep -o '"name":"[^"]*"' | sort | uniq -c | sort -rn
```

### 11.3 Why each collector processor exists ✅

| Processor | Problem it fixes |
|---|---|
| `filter/drop_health` | `/ping` every 2 seconds would otherwise become billable spans |
| `attributes/genai_token_types` | Ballerina writes token counts as strings, so the dashboard's "Total tokens" read 0 |
| `transform/genai_total_tokens` | Adds `gen_ai.usage.total_tokens`, which AWS's queries use |
| `transform/scope_name` | Evaluations only read scopes named `opentelemetry.instrumentation.*`; Ballerina's is `otel` |
| `transform/genai_eval_aliases` | Copies prompt, answer and tool input/output to the attribute names Evaluations reads. Without it every score was a meaningless 1.0: *"Both the task and the candidate response are empty strings"* |
| `resource/agent_identity` | Copies AgentCore's identity onto the spans. Without `deployment.environment.name` they were classed `Generic` and never rolled up under the agent |
| `attributes/agentcore_origin` | Marks spans as coming from an AgentCore Runtime |
| `attributes/session_id` | Copies `gen_ai.conversation.id` to `session.id`, which AWS uses to group a session |

### 11.4 Reading policy decisions

```bash
aws logs filter-log-events --region <REGION> --log-group-name aws/spans \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --filter-pattern '"AuthorizeAction"' --query 'events[].message' --output text
```

Look at these attributes:
- `aws.agentcore.gateway.policy.mode`;
- `aws.agentcore.policy.authorization_decision`;
- `aws.agentcore.policy.determining_policies`;
- `aws.agentcore.policy.allowed_tools` and `denied_tools` (on `PartiallyAuthorizeActions`
  spans).

Decisions on direct model calls in `LOG_ONLY` did not appear within 5 minutes, so test
model-call rules in `ENFORCE`.

### 11.5 Known gaps

- **Separate traces.** The platform's `AgentCore.Runtime.Invoke` span and the agent's
  own spans land in different traces. The Ballerina listener starts a new trace instead
  of continuing AgentCore's.
- **No caller in Gateway spans.** The Gateway's spans don't record which client called
  it.

---

## 12. Evaluation

### 12.1 Online evaluation (continuous scoring of live traffic) ✅

In the console: **AgentCore → Evaluations → Online evaluation → Create.**
- **Data source:** the agent runtime.
- **Evaluators:** pick the built-in evaluators, for example `Builtin.Correctness`,
  `Builtin.GoalSuccessRate`, `Builtin.Helpfulness`, `Builtin.InstructionFollowing` and
  `Builtin.ResponseRelevance`.
- **Sampling:** 100% while testing.

Session-level and trace-level evaluators work with the collector in section 9. Results
were varied and came with real explanations: Correctness 0.88, GoalSuccessRate 0.75,
Helpfulness 0.56.

**Always read the explanation, not just the score.** A uniform 1.0 everywhere means the
judge received empty input.

### 12.2 On-demand evaluation (before a release, or one session at a time) ✅

The `Evaluate` API scores the spans you send it. Tool-level evaluators
(`Builtin.ToolSelectionAccuracy`, `Builtin.ToolParameterAccuracy`) need **`session.id`
on every span**. Ballerina only sets it where the collector copies it (the
`invoke_agent` span). So add it to every span before sending. As emitted, the API
answers `EvaluationInput has spans from more than one session`.

The procedure we used: collect the session's spans from `aws/spans`, set `session.id` on
each one, and send them.

```python
# collect_session.py <REGION> <SESSION_ID>   ->   eval_input.json
import json, subprocess, sys, time
region, session = sys.argv[1], sys.argv[2]

def spans(pattern, minutes=120):
    out = subprocess.run(["aws", "logs", "filter-log-events", "--region", region,
        "--log-group-name", "aws/spans", "--filter-pattern", f'"{pattern}"',
        "--start-time", str(int((time.time() - minutes * 60) * 1000)), "--output", "json"],
        capture_output=True, text=True, check=True).stdout
    return [json.loads(e["message"]) for e in json.loads(out)["events"]]

traces = {s["traceId"] for s in spans(session)}
by_id = {s["spanId"]: s for t in traces for s in spans(t)}
for s in by_id.values():
    s.setdefault("attributes", {})["session.id"] = session
json.dump({"sessionSpans": list(by_id.values())}, open("eval_input.json", "w"))
print(len(by_id), "spans")
```

```bash
# Session level: no target needed
aws bedrock-agentcore evaluate --region <REGION> --evaluator-id Builtin.GoalSuccessRate \
  --evaluation-input file://eval_input.json

# Tool level: target an execute_tool span ({"spanIds": [...]}); trace level: {"traceIds": [...]}
echo '{"spanIds": ["<execute_tool span id>"]}' > target.json
aws bedrock-agentcore evaluate --region <REGION> --evaluator-id Builtin.ToolSelectionAccuracy \
  --evaluation-input file://eval_input.json --evaluation-target file://target.json
```

Result: `ToolSelectionAccuracy` = 1.0, *"The agent called the 'sum' tool with parameters
a=2 and b=3, which directly addresses the user's request..."*.

What worked:
- Every built-in and third-party evaluator worked this way, except two families.
- `Trajectory*` needs a reference trajectory.
- `Skill*` returned empty.

### 12.3 Custom evaluators ⚠️

AWS supports your own LLM judge (model, instructions, scoring scale) and code-based
evaluators (a Lambda). Not yet run against this agent.

### 12.4 Known gap

**Online tool-level scores fail with no diagnostic.** The cause is the same missing
`session.id` on child spans. The collector can't copy an attribute from a parent span to
its children, so the fix has to come from Ballerina: propagate the session to every span,
which AWS's own SDKs do through OTel baggage. This is not implemented yet.

---

## 13. Identity: the agent's token from AgentCore Identity

| Hop | How it authenticates | Status |
|---|---|---|
| Caller → agent | IAM (SigV4) | ✅ |
| Agent → Gateway | Cognito token from a client secret in the runtime's environment | ✅ works, but holds a secret |
| Agent → Gateway | Token from AgentCore Identity's vault, no secret in the agent | ⚠️ code written, not yet deployed |
| Gateway → MCP server and Lambda | Gateway IAM role (SigV4) | ✅ |
| Gateway → OpenAI | API key from the token vault | ✅ |

### 13.1 What the Runtime gives the agent ✅

Each runtime gets a **workload identity** automatically. The Runtime passes the agent a
`WorkloadAccessToken` header **only** in two cases:
- the caller names a user (`--runtime-user-id`, which needs
  `InvokeAgentRuntimeForUser`);
- the runtime uses JWT inbound auth.

| Invocation | `WorkloadAccessToken` in the container |
|---|---|
| IAM, no user id | absent |
| IAM with `--runtime-user-id priya` | **present** |

Under IAM inbound auth the user id is not verified. That's why AWS recommends JWT inbound
auth for real users.

### 13.2 Switching the agent to Identity ⚠️

1. **Store the Gateway's Cognito client in the vault.** AgentCore → Identity → Outbound
   Auth → Add → **OAuth client**:
   - name `gateway-cognito`;
   - the Cognito client id and secret;
   - discovery URL
     `https://cognito-idp.<REGION>.amazonaws.com/<USER_POOL_ID>/.well-known/openid-configuration`.
2. **Grant the agent role** the `GatewayTokenFromIdentity` and `GatewayTokenSecret`
   statements from 5.2.
3. **Update the runtime's environment.** Add
   `BAL_CONFIG_VAR_GATEWAYCREDENTIALPROVIDER=gateway-cognito` and
   `BAL_CONFIG_VAR_AWSREGION=<REGION>`, and **remove** `BAL_CONFIG_VAR_MCPCLIENTSECRET`.
   The update must carry the full configuration (section 14).
4. **Invoke with a user id.** The log should show `gateway token obtained` with
   `tokenSource=agentcore-identity`:

   ```bash
   aws bedrock-agentcore invoke-agent-runtime --region <REGION> --agent-runtime-arn "$ARN" \
     --runtime-session-id "$(uuidgen)$(uuidgen)" --runtime-user-id priya \
     --content-type application/json --accept application/json \
     --cli-binary-format raw-in-base64-out --payload '{"prompt":"Use whoAmI."}' /dev/stdout
   ```

5. **Invoke without a user id.** Expect `no Gateway credentials: invoke with a user id
   ...`. That confirms no secret is left in the agent.

The call the agent makes is AgentCore Identity's `GetResourceOauth2Token`:
- `POST /identities/oauth2/token` on `bedrock-agentcore.<REGION>.amazonaws.com`;
- SigV4-signed with signing name `bedrock-agentcore`, as the runtime role;
- body `{resourceCredentialProviderName, scopes, oauth2Flow: "M2M", workloadIdentityToken}`.

This is what the Python SDK's `@requires_access_token(auth_flow="M2M")` does.

---

## 14. Changing things after deployment

| Change | What to do |
|---|---|
| New agent code | Build and push a new image tag, then update the runtime. **`update-agent-runtime` replaces the whole configuration**: send the image, role, network, protocol **and all environment variables** again. Leaving out `environmentVariables` drops them, and the agent fails to start |
| New or changed tools on the MCP server | Redeploy the MCP runtime, then **sync** the target (Gateway → target → Sync; API `SynchronizeGatewayTargets`). Listing mode Default caches the tool list when the target is created |
| Agent sees old tools | `ai:McpToolKit` reads the tool list once, when the agent is built (first invocation of a session). Start a new session, or update the agent runtime |
| Rename a target | Avoid it. If you must, back up the target, update or delete every policy naming its tools, and start new agent sessions |
| Rotate the OpenAI key | Update the `openai-key` credential provider. Nothing is redeployed |
| Rotate the Cognito client secret | Update the agent runtime's environment (or the `gateway-cognito` provider, once section 13 is in place) |

---

## 15. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Image pushed fine, runtime or Lambda create fails | Missing `--provenance=false` or `--platform linux/arm64` (section 4) |
| Runtime `READY`, log group empty | Wrong protocol (`HTTP` on an MCP image) or wrong port (6.3) |
| MCP server in a crash loop; caller sees 408 | Unknown key in `Config.toml` (section 4). Run the image locally |
| MCP target creation fails with `Authorization error when sending message` | `InvokeMcpRuntime` missing the `/*` entry (5.4), or the MCP runtime has a JWT authorizer (6.3) |
| REST tool returns 403 | Function URL resource policy missing, or missing its `FunctionUrlAuthType` condition (5.5) |
| First REST call times out | Lambda timeout still at the 3-second default (7.2) |
| Agent: `Failed to initialize the MCP client` | Gateway unreachable, or the token was refused. `ai:McpToolKit` fails fast by design |
| Agent: 400 `Failed to fetch outbound api key ... GetResourceApiKey` (then `GetSecretValue`) | Gateway role missing the inference grants (5.4) |
| Agent: 401 `Missing Bearer token` on model calls | Token sent as `x-api-key`. Use the OpenAI provider (8.4) |
| Model calls fail after about an hour in one session | The Cognito token expired. The OpenAI provider can't renew it (9.5) |
| Every `CreatePolicy` fails: *"Policy references an action that does not exist on the target gateway"* | A hyphen in some target name (section 3) |
| `CREATE_FAILED`: "Overly Permissive" / "Overly Restrictive" | Use `--validation-mode IGNORE_ALL_FINDINGS` (10.2) |
| `CREATE_FAILED`: `Insufficient permissions to call gateway` | Your own identity lacks `InvokeGateway` (2.3) |
| ``unexpected token `guardrails` `` | Guardrail policy sent under `cedar`; use the `policy` key (10.2) |
| `ConflictException` on create | A failed policy with that name still exists. Delete it |
| `tools/list` shows every tool under `ENFORCE` | Stale policies naming old actions (10.6) |
| Everything denied after switching to `ENFORCE` | No permit for that tool or for the model call (10.3) |
| `Unsupported protocol version` from the Gateway | Send `MCP-Protocol-Version` (8.5) |
| Evaluation scores all 1.0 | Collector rewrites missing (11.3). Read the explanations |
| `EvaluationInput has spans from more than one session` | `session.id` missing on some spans (12.2) |
| "Total tokens" reads 0 | `attributes/genai_token_types` missing (11.3) |
| Spans show as `Generic` and don't roll up under the agent | `resource/agent_identity` missing, or `start.sh` stripped it (check the container log for `OTEL_RESOURCE_ATTRIBUTES missing`) |
| A `RuntimeClientError (500)` with no detail | Read the agent's log group (9.5) |

---

## 16. What does not work yet

| Gap | Why | Workaround |
|---|---|---|
| Policies or guardrails on tools defined inside the agent | They never cross the Gateway, and Cedar can't look inside the model call's tool list (10.5) | Put the tool behind the Gateway; or a Gateway interceptor Lambda (untested); or `ai:RequiresApproval` |
| Guardrails on the chat conversation at the Gateway | `messages` isn't a string field (10.4) | Bedrock `ApplyGuardrail` from code ([BALLERINA-ON-AGENTCORE.md §2.6](BALLERINA-ON-AGENTCORE.md)) or an interceptor |
| Temporal (session-history) policies | They need an `x-amzn-bedrock-agentcore-policy-session-id` header on every Gateway call, and `ai:McpToolKit` can't add headers | Needs a change in `ballerina/mcp` or `ballerina/ai` |
| Online tool-level evaluation | `session.id` only on the agent span (12.4) | On-demand evaluation with the fix-up in 12.2 |
| One trace per request end to end | The listener starts a new trace (11.5) | None yet |
| Token renewal within a session (OpenAI provider) | Fixed key (9.5) | Keep sessions under an hour, or use the Anthropic forwarder pattern, which renews |
| Agent token from AgentCore Identity | Not yet deployed (13.2) | Client secret in the environment, as now |
| Per-agent rules at the Gateway | The Gateway knows a caller by its Cognito client. Give each agent its own client to tell them apart | Not yet tested |
