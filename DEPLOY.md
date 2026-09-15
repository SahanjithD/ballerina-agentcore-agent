# Deploying this Ballerina agent on Amazon Bedrock AgentCore Runtime

AgentCore Runtime does not care what language your agent is written in. It runs
an **ARM64 container** that speaks a small HTTP contract, so a Ballerina service
is a first-class citizen even though there is no Ballerina SDK for AgentCore.

## The contract the container must satisfy

| Requirement | Value |
|---|---|
| Host / port | `0.0.0.0:8080` |
| Platform | `linux/arm64` (hard requirement) |
| `GET /ping` | `200` + `{"status":"Healthy"}` |
| `POST /invocations` | JSON in, JSON (or SSE) out |
| Session header | `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` |

[`service.bal`](service.bal) implements exactly this and hands the session id to
`ai:Agent.run` as its memory key, so each AgentCore session gets its own
conversation history.

## Test the container locally first

Free, and it catches the mistake that reliably bites (see below):

```bash
docker build -t ballerina-agent:local .
docker run --rm -p 8080:8080 \
  -e BAL_CONFIG_VAR_ANTHROPICAPIKEY="sk-ant-..." ballerina-agent:local

curl localhost:8080/ping
curl -X POST localhost:8080/invocations \
  -H 'Content-Type: application/json' \
  -H 'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: 0123456789012345678901234567890123' \
  -d '{"prompt":"What is 8 plus 9, multiplied by 10?"}'
```

**The env var name is the gotcha.** Ballerina reads a `configurable` from the
environment as `BAL_CONFIG_VAR_` + the variable name **uppercased**:
`anthropicApiKey` → `BAL_CONFIG_VAR_ANTHROPICAPIKEY`. The exact-case spelling is
silently ignored as an unused variable and the agent fails at startup.

On an arm64 machine (Apple Silicon) plain `docker build` already produces an
arm64 image. On an x86 machine or CI runner it does not, and AgentCore rejects
the image with an unhelpful error — hence the explicit
`--platform linux/arm64` inside [`deploy/02-push-image.sh`](deploy/02-push-image.sh).

**`--provenance=false` is the second half of that gotcha.** By default `buildx`
pushes an attestation manifest alongside an OCI manifest list rather than a single
image manifest. AgentCore Runtime rejects that shape with an unhelpful error, and
Lambda rejects it with `image manifest ... not supported`. Every `buildx` call in
[`deploy/`](deploy/) passes the flag for this reason — dropping it produces an image
that pushes cleanly and only fails later, at deploy time.

## One-time setup

1. **Store the Anthropic API key in Secrets Manager.** The agent calls the
   Anthropic API directly (Ballerina has no Bedrock model provider yet), so the
   key travels with the deployment:

   ```bash
   aws secretsmanager create-secret --name anthropic/api-key \
     --secret-string 'sk-ant-...' --region us-east-1
   ```

2. **Review [`deploy/config.env`](deploy/config.env)** — region, ECR repo name,
   agent name. The runtime name must match `[a-zA-Z][a-zA-Z0-9_]{0,47}`;
   underscores are allowed, hyphens are not.

## Deploy

```bash
cd deploy
./01-create-role.sh      # execution role + trust policy
./02-push-image.sh       # buildx --platform linux/arm64, push to ECR
./03-deploy-runtime.sh   # create or update the AgentCore runtime
```

## Invoke

```bash
./04-invoke.sh "What is 8 plus 9, multiplied by 10?"
./05-logs.sh    # tail CloudWatch logs
```

Session ids must be at least 33 characters — `04-invoke.sh` generates one.
Reuse the same id across calls to continue a conversation.

## Connecting an AgentCore Gateway (MCP tools)

`ballerina/ai` ships `ai:McpToolKit`, which speaks MCP streamable HTTP -- the same protocol
AgentCore Gateway exposes. Point two configurables at a gateway and its tools join the local
`sum`/`multiply` functions automatically:

| Configurable | Env var | Meaning |
|---|---|---|
| `mcpServerUrl` | `BAL_CONFIG_VAR_MCPSERVERURL` | The gateway's MCP endpoint. Empty = local tools only. |
| `mcpTokenUrl` | `BAL_CONFIG_VAR_MCPTOKENURL` | OAuth2 token endpoint (Cognito `/oauth2/token`). |
| `mcpClientId` | `BAL_CONFIG_VAR_MCPCLIENTID` | OAuth2 client id. |
| `mcpClientSecret` | `BAL_CONFIG_VAR_MCPCLIENTSECRET` | OAuth2 client secret. |
| `mcpAuthToken` | `BAL_CONFIG_VAR_MCPAUTHTOKEN` | Static bearer token, for servers that use one instead. |

**Pass the OAuth2 credentials, not a token.** AgentCore Gateway's Cognito tokens last one
hour. A token placed in the runtime config stops working after that, and -- because the
toolkit is built with `check` -- the container then fails to *start* on its next recycle,
reading the same dead token. Given `mcpTokenUrl`/`mcpClientId`/`mcpClientSecret`, Ballerina's
HTTP client mints tokens itself and renews them before expiry. `mcpAuthToken` remains for MCP
servers that issue long-lived tokens; OAuth2 wins if both are set.

Scopes are deliberately not configurable. Cognito grants every scope the client is allowed
when none is requested, which sidesteps the resource-server prefix (the scope is
`<resource-server-id>/<scope-name>`, and quick-create may truncate the identifier).

Confirmed on this gateway: the scope Cognito actually grants is
`ballerina-agent-gatewa/genesis-gateway:invoke` — the resource-server id is truncated
to 22 characters (`...gatewa`, not `...gateway`) and the separator before the scope
name is `:`, not `/`. Requesting `genesis-gateway/invoke` returns `invalid_scope`.
Omitting `scope` entirely avoids having to know any of this.

`ai:McpToolKit` calls `listTools` during `init`, so the tool list is fixed when the agent is
built. That means **an unreachable gateway stops the container from starting** -- it exits with
`Failed to initialize the MCP client` rather than serving an agent silently missing half its
tools. If you would rather degrade to local tools, the toolkit has to be built without `check`;
note that Ballerina forbids calling same-module functions while module-level variables are
still initializing, so the error has to be kept as a value rather than handled in a helper.

## Hosting your own tools behind the Gateway

Two Ballerina backends live in [`tools/`](tools/) and attach to the same gateway:

| | [`tools/mcp-server`](tools/mcp-server) | [`tools/rest-api`](tools/rest-api) |
|---|---|---|
| What it is | MCP server (`ballerina/mcp`) | REST service (`ballerina/http`) |
| Hosted on | **AgentCore Runtime**, `serverProtocol: MCP` | **Lambda** container image + Function URL |
| Gateway target | `mcp.mcpServer` | `mcp.openApiSchema` |
| Outbound auth | SigV4 as the gateway role | SigV4 as the gateway role |
| Tools it adds | `countWords`, `whoAmI` | `greetPerson`, `generateUuids` |

### AgentCore hosts the MCP server, but not the REST API

AgentCore Runtime supports MCP natively, so the Ballerina MCP server deploys through
the same ECR pipeline as the agent — only the protocol changes. But the Runtime
contract mounts a **fixed path per protocol**, and that is what rules it out for a
REST API:

| Protocol | Port | Mount path |
|---|---|---|
| HTTP | 8080 | `/invocations`, `/ws` |
| MCP | 8000 | `/mcp` |
| A2A | 9000 | `/` |

There is no route to `/v1/greet/{name}` — every call is funnelled through
`/invocations` — so the REST API has to be hosted elsewhere.

**Lambda Function URLs are the cheapest AWS host that satisfies the Gateway.** The
Gateway needs a publicly trusted TLS certificate, which `*.lambda-url.<region>.on.aws`
provides with no domain, ACM certificate or load balancer. Two alternatives do not
work as well:

- **App Runner** would have been the obvious choice, but it is
  [closed to new customers](https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html).
- **ALB + Fargate** needs a domain and an ACM certificate, because an ALB's default
  `*.elb.amazonaws.com` name has no valid certificate — and an ALB cannot verify
  SigV4, so the gateway would need an API key or OAuth instead.

The [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) is
what lets an unmodified `http:Listener` serve a Function URL. It is copied into the
image as an `/opt/extensions` binary, so it bridges the Lambda Runtime API to a plain
HTTP server and **no Lambda-specific code appears in the Ballerina service at all**.

### No shared secrets on either path

Both targets use `GATEWAY_IAM_ROLE` outbound auth: the gateway signs with SigV4 as
its own execution role. That is only possible because AgentCore Runtime and Lambda
Function URLs both verify SigV4 natively (an ALB or bare EC2 endpoint cannot). So
there is no API key or client secret anywhere in this path — nothing to store,
rotate, or leak. The MCP server needs no configuration secrets either; unlike the
agent, it holds no Anthropic key.

### Deploy

```bash
cd deploy
# Set GATEWAY_ID in config.env first.
./10-deploy-mcp-runtime.sh    # MCP server -> AgentCore Runtime (serverProtocol MCP)
./20-deploy-rest-lambda.sh    # REST API -> Lambda + Function URL, rewrites the spec's server URL
./30-add-gateway-targets.sh   # both targets + the IAM grants the gateway needs
```

`20-deploy-rest-lambda.sh` rewrites the `servers:` URL in
[`gateway/tools-api-openapi.yaml`](gateway/tools-api-openapi.yaml) with the real
Function URL, so run it before `30`.

The agent picks the new tools up **on its next restart**, not immediately —
`ai:McpToolKit` calls `listTools` in its `init`, so the tool list is fixed when the
container boots.

### Testing locally

Neither backend needs AWS to run:

```bash
cd tools/mcp-server && bal run          # then POST JSON-RPC to localhost:8000/mcp
cd tools/rest-api   && bal run          # then curl localhost:8080/v1/greet/you
```

```bash
curl -X POST http://localhost:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### Regenerating the OpenAPI spec

`bal openapi -i service.bal` (after `bal tool pull openapi`) derives a spec from the
service, but its output is **not** Gateway-ready — it is a starting point, not the
artifact. [`gateway/tools-api-openapi.yaml`](gateway/tools-api-openapi.yaml) is
curated from it because the Gateway needs:

- a **static, fully qualified** `servers` URL. `bal openapi` emits a templated
  `{server}:{port}` form, and Gateway rejects dynamic host placeholders as an SSRF risk.
- meaningful **`operationId`s** — the operationId becomes the MCP tool name, and the
  generated `getGreetName` makes a poor one.
- **`summary`/`description`** on every operation, which is what the model reads to
  pick a tool. `bal openapi` does not emit them.
- no `/health` path, which should not be exposed as a tool.

Gateway also rejects `oneOf`/`anyOf`/`allOf`, so keep response schemas flat.

## Notes

- **Config.toml is never baked into the image** — it is listed in
  [`.dockerignore`](.dockerignore) and [`.gitignore`](.gitignore). Local runs
  use it; the container gets the key as an environment variable.
- **The key stays out of the process list.** `03-deploy-runtime.sh` sends the
  request with `--cli-input-json` from a `0600` temp file rather than passing
  the key as a command-line argument, where `ps` would expose it to any other
  process on the machine.
- **The key is still readable from the runtime config** by anyone holding
  `bedrock-agentcore:GetAgentRuntime`. To avoid that, drop the environment
  variable and have the container fetch the secret itself with
  `ballerinax/aws.secretmanager` using the execution role.
- **Streaming.** The contract also accepts `text/event-stream` from
  `/invocations`. To stream token by token, return an `http:Response` with a
  `stream<byte[], error?>` body and switch the agent call to its streaming API.
- **VPC mode** (`networkMode: VPC`) is deliberately not wired up. This agent
  calls `api.anthropic.com`, so VPC mode would still need a NAT gateway
  (~$32/month) and buy nothing. It starts to pay off only once model traffic
  can stay inside AWS, which needs a Ballerina Bedrock provider that does not
  exist yet. If you add one, note that VPC mode also requires private subnets
  in AgentCore-supported AZ *IDs*, `ecr.api`/`ecr.dkr`/`logs` interface
  endpoints, and an **S3 gateway** endpoint.
- **Why no AgentCore CLI?** The `agentcore` starter toolkit expects a Python
  entrypoint. For any other language the documented route is
  [Get started without the AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/getting-started-custom.html)
  — build an ARM64 container, push to ECR, call `create-agent-runtime` — which
  is exactly what `deploy/` does.
