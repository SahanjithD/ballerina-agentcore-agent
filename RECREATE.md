# Adding Ballerina tools to an Amazon Bedrock AgentCore Gateway

A complete, self-contained guide: every source file, Dockerfile and IAM policy you need is
included inline. Follow it top to bottom and you will have a Ballerina MCP server and a
Ballerina REST API callable as tools by an agent.

**Assumed:** you already have an agent running on AgentCore Runtime and an AgentCore
Gateway it connects to. Part 7 shows the agent-side wiring if you need it.

**Placeholders:** `<ACCOUNT>` your AWS account id, `<REGION>` your region (`us-east-1`
below), `<ECR_REPO>` an ECR repository you can push to.

---

## What you end up with

```
  agent on AgentCore Runtime
          │
          ▼
   AgentCore Gateway
    │            │
    │ SigV4      │ SigV4
    ▼            ▼
 MCP server    REST API
 AgentCore     Lambda +
 Runtime       Function URL
 (:8000/mcp)   (arm64 + Web Adapter)
```

Neither backend holds a secret — the Gateway authenticates to both with SigV4 as its own
IAM role.

**Why the REST API is on Lambda and not AgentCore.** AgentCore Runtime mounts one fixed
path per protocol — `/invocations` for HTTP, `/mcp` for MCP. There is no routing to
`/v1/greet/{name}`, so a REST API cannot live there. The Gateway needs a publicly trusted
TLS certificate; a Lambda Function URL gives one with no domain, ACM certificate or load
balancer, and verifies SigV4 natively so no shared secret is required. The
[AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) lets an
unmodified `http:Listener` serve it.

## Prerequisites

- Ballerina **2201.13.5** (Swan Lake Update 13)
- Docker with `buildx`, able to build `linux/arm64`
- AWS CLI v2, credentials with ECR push, Lambda, IAM and `bedrock-agentcore` access
- Python 3 (used for two one-liners)

---

## Part 1 — The MCP server

Create `tools/mcp-server/` with three files.

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

`service.bal` — tool names and descriptions come from the function names and doc comments,
so write them for the model to read:

```ballerina
import ballerina/log;
import ballerina/mcp;
import ballerina/time;

// AgentCore Runtime's MCP protocol contract fixes both the port and the path: the
// container must speak streamable HTTP on `0.0.0.0:8000/mcp`. Neither is negotiable
// -- a server on 8080, or mounted anywhere but /mcp, is simply never reached.
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
    // STATELESS because the Gateway is the only client and it does not carry a session
    // across calls: it syncs the tool list once at target creation, then invokes tools
    // independently. Stateful mode would have AgentCore pin an `Mcp-Session-Id` per
    // container for no benefit here.
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Count the whitespace-separated words in a piece of text.
    #
    # + text - The text whose words should be counted
    # + return - The number of words found
    remote function countWords(string text) returns int {
        // Logged because an AgentCore container that prints nothing is ambiguous: an
        // empty log group reads the same whether the server never started or is
        // serving happily. One line per call distinguishes the two.
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

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

# AgentCore Runtime only runs linux/arm64 images -- always build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/mcp-server
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/mcp-server/target/bin/tools_mcp_server.jar /app/mcp-server.jar

# The MCP protocol contract is port 8000, not the 8080 the HTTP contract uses.
# mcp:StreamableHttpListener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8000
ENTRYPOINT ["java", "-jar", "/app/mcp-server.jar"]
```

Build and run it locally first — it needs no AWS:

```bash
cd tools/mcp-server && bal run

curl -X POST http://localhost:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

---

## Part 2 — The REST API

Create `tools/rest-api/` with three files.

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

`service.bal` — an ordinary Ballerina HTTP service with nothing Lambda-specific in it:

```ballerina
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;

// The Lambda Web Adapter forwards the Function URL request to a normal HTTP server on
// this port (its `AWS_LWA_PORT` default), so the service needs no Lambda-specific code.
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

    // The adapter polls this before it will forward traffic; it is pointed here with
    // AWS_LWA_READINESS_CHECK_PATH so a cold JVM is never handed a real request.
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
        // Bounded deliberately: `count` reaches this straight from a model-generated
        // tool call, so an unbounded value is an easy way to burn the Lambda timeout.
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

`Dockerfile` — the only Lambda-aware part of this package:

```dockerfile
# syntax=docker/dockerfile:1

# Lambda runs this as a container image on arm64 -- build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/rest-api
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy

# The Lambda Web Adapter is an external extension, not a base image: Lambda starts
# the ENTRYPOINT below as the process, and the adapter bridges the Lambda Runtime API
# to a plain HTTP server on AWS_LWA_PORT. That is what lets an unmodified Ballerina
# http:Listener serve a Function URL with no Lambda-specific code in the service.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 /lambda-adapter /opt/extensions/lambda-adapter

# Point the adapter's readiness probe at the service's own health resource so a cold
# JVM is never handed a real request before the listener is up.
ENV AWS_LWA_PORT=8080
ENV AWS_LWA_READINESS_CHECK_PATH=/v1/health

WORKDIR /app
COPY --from=build /home/ballerina/rest-api/target/bin/tools_rest_api.jar /app/rest-api.jar
ENTRYPOINT ["java", "-jar", "/app/rest-api.jar"]
```

`test-event.json`, a Function-URL-shaped event for testing later:

```json
{
  "version": "2.0",
  "routeKey": "$default",
  "rawPath": "/v1/greet/Dasun",
  "rawQueryString": "",
  "headers": {"host": "abc123.lambda-url.us-east-1.on.aws", "accept": "*/*", "user-agent": "AgentCore-Gateway"},
  "requestContext": {
    "accountId": "123456789012",
    "apiId": "abc123",
    "domainName": "abc123.lambda-url.us-east-1.on.aws",
    "http": {"method": "GET", "path": "/v1/greet/Dasun", "protocol": "HTTP/1.1", "sourceIp": "1.2.3.4", "userAgent": "AgentCore-Gateway"},
    "requestId": "test-req-1",
    "routeKey": "$default",
    "stage": "$default",
    "time": "15/Sep/2026:04:22:00 +0000",
    "timeEpoch": 1789200000000
  },
  "isBase64Encoded": false
}
```

Locally:

```bash
cd tools/rest-api && bal run
curl localhost:8080/v1/greet/you
curl "localhost:8080/v1/uuid?count=2"
```

---

## Part 3 — Build and push both images

```bash
aws ecr get-login-password --region <REGION> \
  | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com

cd tools/mcp-server
docker buildx build --provenance=false --platform linux/arm64 \
  -t <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/<ECR_REPO>:tools-mcp --push .

cd ../rest-api
docker buildx build --provenance=false --platform linux/arm64 \
  -t <ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/<ECR_REPO>:tools-rest --push .
```

Both flags are required:

- **`--provenance=false`** — otherwise buildx pushes an attestation manifest alongside an
  OCI manifest list, which AgentCore and Lambda both reject. The push succeeds; the failure
  appears only at deploy time.
- **`--platform linux/arm64`** — AgentCore accepts nothing else, and it must match the
  architecture you choose for the Lambda.

One ECR repository with two tags is fine; separate repositories work equally well.

---

## Part 4 — Deploy the MCP server to AgentCore Runtime

### Execution role

Create an IAM role named e.g. `BedrockAgentCoreRuntime-ballerina_mcp_server`.

Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeRolePolicy",
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock-agentcore.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "<ACCOUNT>"
        },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:*"
        }
      }
    }
  ]
}
```

Inline permissions policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRImageAccess",
      "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": ["arn:aws:ecr:<REGION>:<ACCOUNT>:repository/*"]
    },
    {
      "Sid": "ECRTokenAccess",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "LogGroupManagement",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:CreateLogGroup"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/*"]
    },
    {
      "Sid": "LogResourcePolicy",
      "Effect": "Allow",
      "Action": ["logs:PutResourcePolicy"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/ballerina_mcp_server-*"]
    },
    {
      "Sid": "LogGroupDiscovery",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogGroups"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:*"]
    },
    {
      "Sid": "LogWrite",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": ["arn:aws:logs:<REGION>:<ACCOUNT>:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
    },
    {
      "Sid": "Tracing",
      "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"],
      "Resource": ["*"]
    },
    {
      "Sid": "Metrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } }
    },
    {
      "Sid": "GetAgentAccessToken",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetWorkloadAccessToken",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default",
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:workload-identity-directory/default/workload-identity/ballerina_mcp_server-*"
      ]
    }
  ]
}
```

### Create the runtime

AgentCore → Runtime → Create.

| Field | Value |
|---|---|
| Name | `ballerina_mcp_server` — letters, digits, underscores; **no hyphens** |
| Container image | `<ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/<ECR_REPO>:tools-mcp` |
| Protocol | **MCP** |
| Inbound auth | **IAM** — not Cognito/JWT |
| Execution role | the role above |
| Environment variables | none |

Expand every optional section before creating. The console defaults **protocol to `HTTP`**
and **inbound auth to a JWT authorizer**; either one silently stops the Gateway reaching
the server. Verify:

```bash
aws bedrock-agentcore-control get-agent-runtime --region <REGION> \
  --agent-runtime-id <runtime-id> \
  --query '{protocol:protocolConfiguration.serverProtocol,authorizer:authorizerConfiguration,status:status}'
```

Expect `protocol: MCP`, `authorizer: null`, `status: READY`. If an authorizer is present,
an `update-agent-runtime` call omitting `--authorizer-configuration` clears it.

---

## Part 5 — Deploy the REST API to Lambda

### Execution role

An IAM role e.g. `LambdaExecution-ballerina-tools-rest-api`, with the AWS managed policy
`arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole` attached (CloudWatch
Logs only — the service talks to nothing else). Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Create the function

Lambda → Create function → **Container image**.

| Setting | Value | Where |
|---|---|---|
| Function name | `ballerina-tools-rest-api` | create form |
| Container image URI | `...:tools-rest` | create form |
| Architecture | **arm64** | create form → Additional settings |
| Function URL | enabled, auth **AWS_IAM** | create form → Networking |
| Timeout | **60s** | after create: Configuration → General |
| Memory | **1024 MB** | after create: Configuration → General |

Set timeout and memory immediately — the 3s default is shorter than a JVM cold start, so
every first call fails until you change it. No environment variables are needed; the
adapter settings are baked into the Dockerfile.

Verify:

```bash
aws lambda invoke --function-name ballerina-tools-rest-api --region <REGION> \
  --payload file://tools/rest-api/test-event.json \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

Expect `"statusCode":200` and `"server":"ballerina"`.

---

## Part 6 — Grant the Gateway access, then add the targets

The Gateway signs as its own execution role, normally named
`AmazonBedrockAgentCoreGatewayDefaultServiceRole*`. Find it with:

```bash
aws bedrock-agentcore-control get-gateway --region <REGION> \
  --gateway-identifier <GATEWAY_ID> --query roleArn --output text
```

Add this inline policy to that role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeMcpRuntime",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeAgentRuntime"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:runtime/<MCP_RUNTIME_ID>",
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT>:runtime/<MCP_RUNTIME_ID>/*"
      ]
    },
    {
      "Sid": "InvokeRestFunctionUrl",
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunctionUrl"
      ],
      "Resource": [
        "arn:aws:lambda:<REGION>:<ACCOUNT>:function:ballerina-tools-rest-api"
      ]
    }
  ]
}
```

Include the `/*` entry — invoking with `?qualifier=DEFAULT` addresses a sub-resource, and a
policy with only the bare ARN denies the call.

The Function URL additionally needs a resource-based policy. Use the CLI; it fills in a
condition the console form omits:

```bash
GW_ROLE=$(aws iam get-role --role-name <GATEWAY_ROLE> --query Role.Arn --output text)

aws lambda add-permission --function-name ballerina-tools-rest-api --region <REGION> \
  --statement-id AllowAgentCoreGateway --action lambda:InvokeFunctionUrl \
  --principal "$GW_ROLE" --function-url-auth-type AWS_IAM
```

The statement must end up containing
`"Condition": {"StringEquals": {"lambda:FunctionUrlAuthType": "AWS_IAM"}}`. Without it the
grant covers plain `Invoke` but not Function URL calls, and tool calls return 403.

### Target 1 — MCP server

Gateway → Add target. **MCP target**, **Do not use passthrough**, target type
**MCP server**.

The console shows no endpoint; build it from the runtime ARN, percent-encoded as a single
path segment:

```bash
python3 -c "import urllib.parse,sys;print('https://bedrock-agentcore.<REGION>.amazonaws.com/runtimes/'+urllib.parse.quote(sys.argv[1],safe='')+'/invocations?qualifier=DEFAULT')" '<MCP_RUNTIME_ARN>'
```

Listing mode **Default**. Outbound auth **IAM Role**, service `bedrock-agentcore`, region
`<REGION>`.

Creating this target runs `tools/list` against your server immediately, so it succeeds or
fails straight away.

### Target 2 — REST API

Gateway → Add target. **MCP target**, **Do not use passthrough**, target type **REST API**.
Outbound auth **IAM Role**, service `lambda`, region `<REGION>`.

Paste this spec, with the `servers:` URL replaced by your Function URL:

```yaml
openapi: 3.0.3
info:
  title: Ballerina Tools API
  description: >-
    A small Ballerina REST service hosted on AWS Lambda behind a Function URL,
    exposed to agents as MCP tools by AgentCore Gateway.
  version: "1.0.0"
servers:
  # Rewritten by deploy/20-deploy-rest-lambda.sh with the real Function URL.
  # Gateway requires a static, fully qualified HTTPS URL here -- it rejects the
  # templated `{server}:{port}` form that `bal openapi` emits by default, and
  # dynamic host placeholders are an SSRF risk it warns about explicitly.
  - url: https://REPLACE_WITH_FUNCTION_URL/v1
paths:
  /greet/{name}:
    get:
      # Gateway derives the MCP tool name from operationId, and the model picks the
      # tool by reading summary/description -- so all three are load-bearing. The
      # `bal openapi` defaults (getGreetName) are accurate but make poor tool names.
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
                  message:
                    type: string
                  servedBy:
                    type: string
                  utcTime:
                    type: string
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
                  uuids:
                    type: array
                    items:
                      type: string
                  count:
                    type: integer
        "400":
          description: count was outside the range 1 to 20.
          content:
            application/json:
              schema:
                type: object
                properties:
                  message:
                    type: string
```

This target does no connectivity check at creation — it reports Ready from the spec alone,
and problems surface on the first tool call.

**If you write your own spec**, `bal openapi -i service.bal` is a starting point but needs
editing: `servers` must be a static fully-qualified URL (the generated `{server}:{port}`
template is rejected); `operationId` becomes the tool name the model sees; every operation
needs `summary` and `description`, which `bal openapi` does not emit; remove paths that
should not be tools; and keep schemas flat, since `oneOf`/`anyOf`/`allOf` are unsupported.

---

## Part 7 — The agent side

For reference, this is how the agent consumes the Gateway. `ai:McpToolKit` speaks MCP
streamable HTTP, and its tools join the agent's local ones:

```ballerina
import ballerina/ai;
import ballerina/http;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;
configurable anthropic:ANTHROPIC_MODEL_NAMES modelType = anthropic:CLAUDE_OPUS_4_6;

// An AgentCore Gateway -- or any MCP server -- speaking streamable HTTP. Its tools are
// discovered at startup and offered to the agent alongside the local ones below.
// Leave empty to run with local tools only.
configurable string mcpServerUrl = "https://<GATEWAY_ID>.gateway.bedrock-agentcore.<REGION>.amazonaws.com/mcp";

// Preferred for AgentCore Gateway: hand over the OAuth2 client credentials rather than a
// token. Gateway tokens are short-lived (Cognito issues one hour), and a token pasted into
// the runtime config would strand the container once it expired -- including at restart,
// when it would read the same dead token and fail to boot.
configurable string mcpTokenUrl = "";
configurable string mcpClientId = "";
configurable string mcpClientSecret = "";

// Fallback for MCP servers that take a long-lived static token instead.
configurable string mcpAuthToken = "";

@ai:AgentTool
isolated function sum(int a, int b) returns int => a + b;

@ai:AgentTool
isolated function multiply(int a, int b) returns int => a * b;

final ai:ModelProvider claudeModel = check new anthropic:ModelProvider(anthropicApiKey, modelType);

// Ballerina's HTTP client fetches a token from `tokenUrl` and renews it before expiry, so
// nothing here goes stale. Scopes are omitted deliberately: Cognito then grants every scope
// the client is allowed, which avoids depending on the exact resource-server prefix.
final http:OAuth2ClientCredentialsGrantConfig? oauthAuth = mcpTokenUrl == "" ? ()
    : {tokenUrl: mcpTokenUrl, clientId: mcpClientId, clientSecret: mcpClientSecret};

final http:BearerTokenConfig? tokenAuth = mcpAuthToken == "" ? () : {token: mcpAuthToken};

// OAuth2 wins when both are supplied.
final http:ClientAuthConfig? gatewayAuth = oauthAuth ?: tokenAuth;

// Connects at startup: `ai:McpToolKit` calls `listTools` in its `init`, so the tool list is
// fixed once the agent is built. An unreachable Gateway therefore stops the container from
// starting rather than silently serving an agent that is missing half its tools.
// See DEPLOY.md if you would rather degrade to local tools instead.
final ai:McpToolKit? gateway = mcpServerUrl == "" ? ()
    : check new ai:McpToolKit(mcpServerUrl, auth = gatewayAuth);

final ai:Agent assistantAgent = check new (
    systemPrompt = {
        role: "Assistant",
        instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
    },
    model = claudeModel,
    // Gateway tools join the local ones only if the connection succeeded. Parens are
    // required: `is T ?` would otherwise parse as the optional type `T?`.
    // The cast is safe under the guard: Ballerina does not narrow module-level variables.
    tools = (gateway is ai:McpToolKit) ? [sum, multiply, <ai:McpToolKit>gateway] : [sum, multiply]
);
```

---

## Part 8 — Restart the agent and verify

`ai:McpToolKit` calls `listTools` in its `init`, so the tool list is fixed when the agent's
container starts. A running agent will not see the new targets.

Console: Runtime → your agent → **Update runtime** → save, which replaces the containers.
If you script this, supply the full configuration — `update-agent-runtime` replaces rather
than patches, so omitting `environmentVariables` drops the agent's API keys and it fails to
start.

Then ask the agent something that needs both backends, e.g. *"Count the words in 'the quick
brown fox', then generate 2 UUIDs"*. Asking it to list its tools should show `countWords`,
`whoAmI`, `greetPerson` and `generateUuids`.

---

## Part 9 — Observability (optional)

Metrics — invocations, errors, sessions, latency, vCPU, memory — are service-vended and
need no setup. For traces:

1. **CloudWatch → Application Signals (APM) → Transaction Search → Enable**, selecting
   *ingest spans as structured logs*. Account-wide, billed under the Application Signals plan.
2. Raise the trace indexing rate from its 1% default, or a handful of test invocations index
   nothing:
   ```bash
   aws xray update-indexing-rule --region <REGION> --name "Default" \
     --rule '{"Probabilistic": {"DesiredSamplingPercentage": 100}}'
   ```
3. Enable the **Tracing** toggle on each runtime and on the Gateway. Spans are captured from
   that point on; nothing is backfilled.

Dashboards lag ingestion by 10–15 minutes. To check immediately:

```bash
aws logs tail aws/spans --region <REGION> --since 30m \
  | grep -o '"name":"[^"]*"' | sort | uniq -c | sort -rn
```

Token counts and cost stay empty. They come from GenAI spans emitted by the ADOT SDK, which
exists for Python, JS and Java only — there is no Ballerina distro, and AWS does not support
the ADOT Collector as a substitute.

---

## Part 10 — Calling the agent over HTTP (optional)

A Ballerina client that posts directly to the runtime's data-plane URL, signing with
`ballerinax/aws.auth`. `tools/chat/Ballerina.toml`:

```toml
[package]
org = "dasun"
name = "tools_chat"
version = "0.1.0"
distribution = "2201.13.5"

[[dependency]]
org = "ballerinax"
name = "aws"
version = "1.0.2"
```

`tools/chat/main.bal`:

```ballerina
import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerinax/aws.auth;

// Talk to the deployed agent over plain HTTPS -- no AWS CLI, no second language.
// `ballerinax/aws.auth` resolves credentials through the standard chain (env vars,
// AWS_PROFILE, ~/.aws, SSO, IMDS) and produces the SigV4 headers; `ballerina/http`
// sends the request.

configurable string region = "us-east-1";
configurable string runtimeArn = ?;

// Reuse one session id for the whole conversation: AgentCore pins a session to a
// container, and `service.bal` passes it to `ai:Agent.run` as the memory key. A new
// id per turn is what makes an agent forget you between messages.
configurable string sessionId = "";

const string SERVICE = "bedrock-agentcore";

public function main() returns error? {
    auth:CredentialProvider credentials = check new (auth:DEFAULT_CREDENTIALS);
    string host = string `${SERVICE}.${region}.amazonaws.com`;

    // The ARN is one path segment, so its colons and slash must be percent-encoded
    // on the wire. The SAME pre-encoded path is handed to the signer, together with
    // `s3PathMode` -- see the note on the signing call below.
    string signedPath = string `/runtimes/${encodeSegment(runtimeArn)}/invocations`;
    string wirePath = string `${signedPath}?qualifier=DEFAULT`;

    // AgentCore requires a session id of at least 33 characters.
    string session = sessionId == "" ? uuid:createType4AsString() + uuid:createType4AsString() : sessionId;

    http:Client agent = check new (string `https://${host}`);

    io:println(string `runtime ${runtimeArn}`);
    io:println(string `session ${session}`);
    io:println("Type your message. Blank line or \"exit\" to quit.\n");

    while true {
        string prompt = io:readln("you > ").trim();
        if prompt == "" || prompt == "exit" || prompt == "quit" {
            break;
        }

        byte[] payload = {"prompt": prompt}.toJsonString().toBytes();
        auth:Credentials creds = check credentials.getCredentials();
        map<string> signed = check auth:getSignedHeaders({
            method: "POST",
            host: host,
            path: signedPath,
            queryParams: {"qualifier": "DEFAULT"},
            headers: {
                "content-type": "application/json",
                "accept": "application/json",
                // Must be signed, not just sent: AgentCore rejects the request if this
                // header is absent from the signature.
                "x-amzn-bedrock-agentcore-runtime-session-id": session
            },
            payload: payload,
            // `s3PathMode` on a non-S3 service looks wrong, but it is required here.
            // SigV4 canonicalises the path by encoding the ALREADY-ENCODED URI again,
            // so the ARN's slash must end up as %252F. Left to itself this signer
            // encodes twice while treating "/" as a path separator, which yields a
            // literal "/" where AWS expects %252F, and every request 403s. Passing the
            // pre-encoded path with `s3PathMode` (encode once, do not normalise)
            // produces exactly the canonical URI AWS computes. Verified byte-for-byte
            // against botocore's SigV4Auth; do not "simplify" this.
            s3PathMode: true
        }, creds, region, SERVICE);

        http:Request request = new;
        request.setBinaryPayload(payload, "application/json");
        request.setHeader("accept", "application/json");
        request.setHeader("x-amzn-bedrock-agentcore-runtime-session-id", session);
        foreach [string, string] [name, value] in signed.entries() {
            request.setHeader(name, value);
        }

        http:Response|error response = agent->post(wirePath, request);
        if response is error {
            io:println(string `agent> request failed: ${response.message()}
`);
            continue;
        }
        io:println(string `agent> ${check render(response)}
`);
    }

    check credentials.close();
    io:println(string `
Session ${session} ended.`);
}

# Renders the runtime's reply, falling back to the raw body when it is not the
# `{"response": ..., "status": ...}` shape the agent normally returns.
#
# + response - The HTTP response from the runtime
# + return - Text to display, or an error if the body cannot be read
isolated function render(http:Response response) returns string|error {
    string body = check response.getTextPayload();
    if response.statusCode != 200 {
        return string `HTTP ${response.statusCode} ${body}`;
    }
    json parsed = check body.fromJsonString();
    if parsed is map<json> {
        json text = parsed["response"] ?: parsed["message"] ?: ();
        if text is string {
            return text;
        }
    }
    return body;
}

# Percent-encodes a value so it survives as a single path segment. The runtime ARN
# contains `:` and `/`, both of which must become %3A/%2F or the URL addresses the
# wrong resource.
#
# + value - The raw value, e.g. a runtime ARN
# + return - The encoded segment
isolated function encodeSegment(string value) returns string {
    string out = "";
    foreach string:Char c in value {
        if isUnreserved(c) {
            out += c;
            continue;
        }
        foreach byte b in c.toBytes() {
            out += "%" + b.toHexString().toUpperAscii().padZero(2);
        }
    }
    return out;
}

# RFC 3986 unreserved characters, which must be left alone when encoding.
#
# + c - The character to test
# + return - Whether the character may appear unencoded
isolated function isUnreserved(string:Char c) returns boolean =>
    (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
        || c == "-" || c == "." || c == "_" || c == "~";
```

```bash
cd tools/chat
BAL_CONFIG_VAR_RUNTIMEARN='<AGENT_RUNTIME_ARN>' bal run
```

Note the `s3PathMode` handling in the signing call — SigV4 canonicalises by encoding the
already-encoded URI again, so the ARN's `/` must become `%252F`, and the default path
handling produces a literal `/` and a 403.

Reuse one session id for the whole conversation. `ai:Agent` defaults to an in-process
`ShortTermMemory` keyed by that id, so a new id per request means no history. That memory
lives in the container and is lost on restart; for durable history, configure an AgentCore
Memory resource and pass it as the agent's `memory`.

---

## If something is wrong

| Symptom | Check |
|---|---|
| Target creation fails with an authorization error | Part 6 policy, and that the runtime has no JWT authorizer (Part 4) |
| Target syncs unsuccessfully | Runtime protocol is `MCP`, not `HTTP` (Part 4) |
| Runtime is `READY` but its log group is empty | Nothing reaches the container — wrong protocol or port |
| Tool call returns 403 | Function URL resource policy and its `FunctionUrlAuthType` condition (Part 6) |
| Agent does not see the new tools | Restart it (Part 8) |
| Agent container will not start | Gateway unreachable; `ai:McpToolKit` fails fast by design |
| Image pushed fine but deploy fails | Missing `--provenance=false` (Part 3) |
