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

`ai:McpToolKit` calls `listTools` during `init`, so the tool list is fixed when the agent is
built. That means **an unreachable gateway stops the container from starting** -- it exits with
`Failed to initialize the MCP client` rather than serving an agent silently missing half its
tools. If you would rather degrade to local tools, the toolkit has to be built without `check`;
note that Ballerina forbids calling same-module functions while module-level variables are
still initializing, so the error has to be kept as a value rather than handled in a helper.

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
