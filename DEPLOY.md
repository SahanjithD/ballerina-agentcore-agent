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

## One-time setup

1. **Store the Anthropic API key in Secrets Manager.** The agent calls the
   Anthropic API directly (Ballerina has no Bedrock model provider yet), so the
   key travels with the deployment:

   ```bash
   aws secretsmanager create-secret --name anthropic/api-key \
     --secret-string 'sk-ant-...' --region us-east-1
   ```

2. **Review [`deploy/config.env`](deploy/config.env)** — region, ECR repo name,
   agent name. Note that the runtime name must match `[a-zA-Z][a-zA-Z0-9_]{0,47}`;
   underscores are allowed, hyphens are not.

## Deploy

```bash
cd deploy
./01-create-role.sh      # execution role + trust policy
./02-push-image.sh       # buildx --platform linux/arm64, push to ECR
./03-deploy-runtime.sh   # create or update the AgentCore runtime
```

`03-deploy-runtime.sh` reads the secret and passes it to the runtime as
`BAL_CONFIG_VAR_ANTHROPICAPIKEY`. That is Ballerina's environment-variable form
of a `configurable`: the prefix `BAL_CONFIG_VAR_` plus the variable name
**uppercased** (`anthropicApiKey` → `ANTHROPICAPIKEY`). The exact-case spelling
is rejected as an unused environment variable.

## Invoke

```bash
./04-invoke.sh "What is 8 plus 9, multiplied by 10?"
./05-logs.sh    # tail CloudWatch logs
```

Session ids must be at least 33 characters — `04-invoke.sh` generates one.
Reuse the same id across calls to continue a conversation.

## Test the container locally first

```bash
docker buildx build --platform linux/arm64 -t ballerina-agent:local --load .
docker run --rm -p 8080:8080 \
  -e BAL_CONFIG_VAR_ANTHROPICAPIKEY="sk-ant-..." ballerina-agent:local

curl localhost:8080/ping
curl -X POST localhost:8080/invocations \
  -H 'Content-Type: application/json' \
  -H 'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: 0123456789012345678901234567890123' \
  -d '{"prompt":"What is 8 plus 9, multiplied by 10?"}'
```

## Running in a VPC (`networkMode: VPC`)

Switching to VPC mode is **not** just a flag change. Two things are independent:

| Axis | Controlled by | Decides |
|---|---|---|
| Where the model call goes | the Ballerina model provider | Anthropic's public API vs. Bedrock inside AWS |
| Where the runtime's ENIs live | `networkMode` | AWS-managed vs. your subnets |

VPC mode works today with the Anthropic provider, but the container still has
to reach `api.anthropic.com`, so the private subnets need a **NAT gateway**.
There is no `ballerinax/ai.aws.bedrock` module yet (Central has openai, azure,
anthropic, mistral, deepseek, ollama, openrouter and vertex), so the fully
private setup -- no NAT, model traffic over a `bedrock-runtime` interface
endpoint -- is not reachable from Ballerina without writing a Bedrock client.

### What VPC mode requires

- `networkModeConfig` with `subnets` (1-16) and `securityGroups` (1-16).
- **Private** subnets. A public subnet does not give the ENI internet access --
  AgentCore assigns it a private IP only. Internet egress means private subnets
  routed to a NAT gateway in a public subnet.
- Subnets in **AgentCore-supported AZ IDs**. See
  [`deploy/supported-azs.env`](deploy/supported-azs.env); `us-east-1` for
  instance only supports `use1-az1`, `use1-az2` and `use1-az4`. Note these are
  AZ *IDs*, not names -- names are shuffled per account.
- The service-linked role `AWSServiceRoleForBedrockAgentCoreNetwork`, created
  automatically on first use if the calling principal has
  `iam:CreateServiceLinkedRole`.
- VPC endpoints -- required with no internet path, and worth having regardless
  to dodge NAT data-processing charges: `ecr.api`, `ecr.dkr` and `logs`
  (interface), plus `s3` (**gateway** -- ECR layers are stored in S3, and
  AgentCore re-pulls the image periodically). Since the May 2026 rollout
  AgentCore no longer provisions a service-managed S3 gateway, so this one is
  mandatory; `requireServiceS3Endpoint` is rejected on new runtimes.
- `enableDnsSupport` and `enableDnsHostnames` both true on the VPC.
- The execution role needs **no** EC2/ENI permissions -- the service-linked
  role handles those. It would need `bedrock:InvokeModel` added back once a
  Bedrock provider is in use; it is deliberately absent today.

### Scripted

```bash
cd deploy
./06-create-vpc.sh          # VPC, subnets, NAT, security groups, endpoints
# append the printed NETWORK_MODE / AGENT_SUBNETS / AGENT_SECURITY_GROUPS
./03-deploy-runtime.sh      # redeploys the runtime into the VPC
```

`06-create-vpc.sh` creates a NAT gateway by default (~$32/month while it
exists); set `CREATE_NAT=false` if the agent needs no internet egress, and
`CREATE_BEDROCK_ENDPOINT=true` once model traffic should stay inside AWS.

## Notes

- **Config.toml is never baked into the image** — it is listed in
  [`.dockerignore`](.dockerignore). Local runs use it; the container uses the
  environment variable.
- **Streaming.** The contract also accepts `text/event-stream` from
  `/invocations`. To stream token by token, return an `http:Response` with a
  `stream<byte[], error?>` body and switch the agent call to its streaming API.
- **Why no AgentCore CLI?** The `agentcore` starter toolkit expects a Python
  entrypoint. For any other language the documented route is
  [Get started without the AgentCore CLI](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/getting-started-custom.html)
  -- build an ARM64 container, push to ECR, call `create-agent-runtime` --
  which is exactly what `deploy/` does.
- **Secrets.** `ballerinax/aws.secretmanager` is on Central, so the container
  could fetch the key itself using the execution role instead of receiving it
  as an environment variable in the runtime config.
