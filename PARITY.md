# Ballerina parity with the AgentCore SDKs

What Ballerina needs so that an agent built with `ballerina/ai` gets the same support on
Amazon Bedrock AgentCore as an agent written in Python, Java or .NET.

This is a living document. It is updated as we learn more; see the [change log](#change-log)
at the end. Last updated: 2026-11-03.

Related documents:
- [GAPS.md](GAPS.md): the identity, governance, observability and evaluations gaps in
  detail, with library code, workarounds and links to the issues we filed.
- [BALLERINA-ON-AGENTCORE.md](BALLERINA-ON-AGENTCORE.md): every workaround we use today, and why.
- [GUIDE.md](GUIDE.md): step-by-step deployment.
- [LEARN.md](LEARN.md): the fundamentals and the whole system explained.

**Status legend**

| Mark | Meaning |
|---|---|
| ✅ | Works today, proven on our live deployment |
| 🔧 | Works today, but only through a workaround we wrote |
| ❌ | Not possible in Ballerina today |
| ? | Not verified yet |

Facts about the other languages come from their official repositories, AWS documentation
and AWS blogs, read on 2026-10-28 (see [Sources](#sources)). Where a source did not say
whether a feature exists, the tables say "not seen", not "no".

---

## 1. The short answer

Anything AgentCore enforces **on the server side** already works for Ballerina exactly as
it does for every other language: Runtime isolation, Gateway, Cedar policy, tool-menu
filtering, guardrails, CloudWatch and online evaluations at session and trace level. The
gaps are all on the **client side**, where the agent's own code must do something: read
the request context, fetch tokens, sign requests, store memory, stream output or emit
telemetry in a particular shape.

Python, Java and .NET close those gaps with three layers of software. Ballerina has
none of the three yet:

| Layer | What it gives | Python | Java | .NET | Ballerina |
|---|---|---|---|---|---|
| 1. Generated AWS SDK clients | Every AgentCore API as a typed call, signed, retried and paginated | `boto3` | `software.amazon.awssdk:bedrockagentcore` | `AWSSDK.BedrockAgentCore` | ❌ none. We sign raw HTTP calls with `ballerinax/aws.auth` |
| 2. AgentCore SDK | Runtime contract, identity, memory, tools, in the language's own style | `bedrock-agentcore` (AWS) | Spring AI AgentCore (community, GA April 2026) | `AWS.AgentCore.Hosting` (AWS, blog August 2026) | ❌ none |
| 3. Tooling and instrumentation | Project templates, deploy CLI, auto-instrumentation recognised by Evaluations | AgentCore CLI, ADOT | Maven starters, ADOT | `dotnet aws deploy`, Aspire | ❌ container path only; telemetry fixed up by a collector |

So "same support" means building the Ballerina equivalent of layers 1 and 2, and fixing a
handful of upstream modules (`ballerina/ai`, `ballerina/mcp`, `ballerina/otel`,
`ballerinax/ai.aws.dynamodb`) so that layer 3 is not needed as a workaround.

---

## 2. What each language has today

### 2.1 Python: `bedrock-agentcore` (the reference)

The most complete SDK. Its source tree has these modules:

| Module | What it provides |
|---|---|
| `runtime` | `BedrockAgentCoreApp`: `/invocations`, `/ping`, `/ws`; decorators `@app.entrypoint`, `@app.ping`, `@app.websocket`, `@app.async_task`; `add_async_task` / `complete_async_task`; automatic `Healthy` / `HealthyBusy`; generators streamed as SSE; `RequestContext` filled from headers; JSON logs with `requestId` and `sessionId`; trace flush after each invocation; `serve_a2a` (A2A) and `serve_ag_ui` / `AGUIApp` (AG-UI); a shell module; a runtime client |
| `identity` | Decorators `@requires_access_token` (flows `M2M`, `USER_FEDERATION`, `ON_BEHALF_OF_TOKEN_EXCHANGE`; scopes, audiences, resources, `on_auth_url`, `callback_url`, `force_authentication`, `token_poller`, custom state and parameters), `@requires_api_key`, `@requires_iam_access_token` (STS web identity JWT), `@requires_wat`. Local development fallback that creates a workload identity and a user id |
| `memory` | `MemoryClient`, control plane client, session manager, Strands integration (session manager, memory store, converters) |
| `tools` | Code Interpreter client, Browser client, Web Search client |
| `gateway` | Gateway client; a Strands plugin for semantic tool search |
| `evaluation` | Evaluation client, dataset client, on-demand and batch runners, user simulator, custom code-based evaluators (decorator), adapters for Ragas, DeepEval and Autoevals, span collectors and serializers |
| `policy` | Policy client |
| `payments` | Payment client and manager, Strands and LangGraph integrations |
| `knowledge_base` | Knowledge base client |
| `config_bundle` | Configuration bundles, read through OTel baggage (also experiment ARN and variant) |
| `services` | Identity service, resource policy |

A TypeScript SDK (`bedrock-agentcore` on npm) follows the same shape: Runtime, A2A, Code
Interpreter, Browser, Web Search, Identity (`withAccessToken`, `withApiKey`), Memory.
Gateway and Observability are listed there as "coming soon".

### 2.2 Java: Spring AI AgentCore

An open source community project (`org.springaicommunity`), generally available since
April 2026. Java 17 or later, Spring Boot 4.

| Artifact | What it provides |
|---|---|
| `spring-ai-agentcore-runtime-starter` | `/invocations` and `/ping` auto-configured; `@AgentCoreInvocation`; `AgentCoreContext`, `AgentCoreHeaders`; `Flux<String>` becomes SSE; `Healthy` / `HealthyBusy` with async task detection; rate limiting |
| `spring-ai-agentcore-identity` | Workload tokens, API keys, OAuth 2.0 credentials, Runtime header integration |
| `spring-ai-agentcore-memory` | Short-term memory (sliding window) and long-term memory (semantic, preference, summary, episodic) as Spring AI advisors |
| `spring-ai-agentcore-browser` | Browser tools (Playwright) |
| `spring-ai-agentcore-code-interpreter` | Code Interpreter tools, with an artifact store for generated files |
| `spring-ai-agentcore-payments` | x402 payments |
| `spring-ai-agentcore-evaluations`, `spring-ai-agentcore-otel-extension` | Present in the repository; contents not checked |

Underneath, the generated AWS SDK for Java 2.x (`software.amazon.awssdk:bedrockagentcore`)
covers every API.

### 2.3 .NET: `AWS.AgentCore.Hosting`

Published by AWS (developer blog, August 2026), built on ASP.NET Core, Microsoft Agent
Framework and Microsoft.Extensions.AI.

| Package | What it provides |
|---|---|
| `AWS.AgentCore.Hosting` | `[AgentCoreStartup]`, `[AgentCoreHandler]` with a source generator, or `AddAgentCore()` / `MapAgentCore<T>()`; `/invocations` on 8080; `IAsyncEnumerable<string>` for streaming; `AgentCoreRuntimeContext` (session id, request id, custom headers); AgentCore Memory by `MemoryId`, loaded before and saved after each invocation; middleware hooks |
| `AWS.AgentCore.Testing` | A local runtime emulator for integration tests, with a memory emulator |
| `Aspire.Hosting.AWS` | Local development and `aspire deploy` (preview) |

Identity, Browser, Code Interpreter and observability were not covered in the blog post.
The generated `AWSSDK.BedrockAgentCore` package covers every API.

### 2.4 Ballerina today

| Package | What we use it for |
|---|---|
| `ballerina/http` | The Runtime contract, written by hand in [service.bal](service.bal) |
| `ballerina/ai` 1.16.0 | The agent, memory interface, tools, MCP toolkit base, human approval |
| `ballerina/mcp` 1.3.0 | The Gateway client, and our MCP tool server ([tools/mcp-server](tools/mcp-server)) |
| `ballerinax/ai.aws.bedrock` | Bedrock models with the execution role, plus a guardrail |
| `ballerinax/ai.aws.dynamodb` | Conversation memory (needs a static access key) |
| `ballerinax/aws`, `ballerinax/aws.auth` | Endpoint resolution and SigV4 signing for the Identity call in [identity.bal](identity.bal) |
| `ballerinax/aws.secretmanager` | Reading the memory table's key |
| `ballerina/otel`, `ballerina/observe` | Traces, fixed up by a collector in the container ([otel-collector.yaml](otel-collector.yaml)) |

There is no Ballerina package for AgentCore itself.

---

## 3. Feature by feature

Columns: **Py** Python SDK, **Java** Spring AI AgentCore, **.NET** AgentCore Hosting.
"API" means only the generated AWS SDK call exists, with no convenience wrapper seen.

### 3.1 Runtime contract (HTTP protocol)

AWS requires: host `0.0.0.0`, port `8080`, ARM64 image, `POST /invocations` (JSON in, JSON
or SSE out), `GET /ping`, optional WebSocket `/ws`.

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| `/invocations` and `/ping` | yes | yes | yes | 🔧 hand-written service | A reusable listener or service type |
| Typed request context (session id, request id, workload token, OAuth2 callback URL, `Authorization`, allowlisted headers) | yes | yes | yes (session, request, headers) | 🔧 headers read one by one | An `agentcore:Context` filled by the listener |
| `HealthyBusy` while background work runs, with async task tracking | yes | yes | not seen | ❌ ping always `Healthy` | Task tracking that drives `/ping`. Note the AWS rule: set `time_of_last_update` only when the status changes, or sessions never go idle |
| SSE streaming of the answer | yes | yes | yes | ❌ | `ballerina/http` can already return SSE (`http:SseEvent`). Missing: `ai:Agent` and `ai:ModelProvider` return the whole answer at once, so there is nothing to stream. Needs streaming in `ballerina/ai` and the model providers |
| WebSocket `/ws` | yes | not seen | not seen | ❌ not wired | `ballerina/websocket` exists; needs wiring into the same listener on 8080 |
| JSON logs carrying request and session ids | yes | ? | `ILogger` | 🔧 JSON logs with trace ids via config; session id added per log call | Put request and session ids into the log context automatically |
| Rate limiting at the agent | not seen | yes | not seen | ❌ | Optional |
| ARM64 image | n/a | n/a | n/a | ✅ | Nothing. Build with `--platform linux/arm64 --provenance=false` |

### 3.2 Other Runtime protocols

| Protocol | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| MCP server (port 8000, `/mcp`, streamable HTTP) | yes (MCP libraries) | not seen | not seen | ✅ `ballerina/mcp`, stateless, proven | Nothing |
| A2A (agent to agent) | `serve_a2a` | not seen | not seen | ❌ no A2A module | An A2A server and client for `ballerina/ai` |
| AG-UI | `serve_ag_ui`, `AGUIApp` | not seen | not seen | ❌ | An AG-UI event stream (depends on streaming, 3.1) |

### 3.3 Identity (outbound credentials)

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| Read the workload access token from the invocation | yes | yes | API | 🔧 manual header read | Part of the context (3.1) |
| Machine-to-machine OAuth token (`GetResourceOauth2Token`, flow `M2M`) | `@requires_access_token` | yes | API | 🔧 [identity.bal](identity.bal), one signed HTTP call | A reusable client or annotation ([#2850](https://github.com/wso2/product-integrator/issues/2850)) |
| API key from the vault (`GetResourceApiKey`) | `@requires_api_key` | yes | API | ❌ (same shape as M2M, not written) | Same client |
| User sign-in on the user's behalf (`USER_FEDERATION`: authorization URL, callback, polling, `CompleteResourceTokenAuth`) | yes | OAuth 2.0 (details not checked) | API | ❌ | The full three-legged flow, plus a way to send the sign-in URL back to the caller (needs streaming or a second call) |
| Token exchange on behalf of a user (`ON_BEHALF_OF_TOKEN_EXCHANGE`) | yes | not seen | API | ❌ | Same client |
| IAM-issued JWT for outbound calls (`@requires_iam_access_token`, STS web identity) | yes | not seen | API | ❌ | An STS call; `ballerinax/aws` may not cover it (?) |
| Local development without the Runtime (create a workload identity, `GetWorkloadAccessTokenForUserId`) | yes | ? | API | ❌ | A local fallback, so the same code runs under `bal run` |
| Supply a token to an MCP toolkit per invocation | n/a (frameworks do it) | n/a | n/a | 🔧 `ai:Context` plus [gateway_toolkit.bal](gateway_toolkit.bal) | First-class support in `ai:McpToolKit` (3.6) |

**Why `ballerina/ai`'s own agent ID feature does not fill this gap.** `ai:Credential` with a
per-tool `AgentIdAuthConfig` speaks only the WSO2 Identity Server / Asgardeo app-native
login (`/authorize` with `response_mode=direct`, then `/authn` with the agent id and secret
as username and password, then `/token`). Cognito and AgentCore Identity do not offer that
API. It also requires a long-lived agent secret inside the container, which AgentCore
Identity exists to remove, and it gives no hook for another token source. One untested
option: point the Gateway's inbound JWT authorizer at Asgardeo, which would make it work at
the cost of the agent holding a secret again.

### 3.4 Models

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| Bedrock models with the execution role | yes | yes | yes | ✅ `ballerinax/ai.aws.bedrock`, `auth:DEFAULT_CREDENTIALS` | Nothing |
| Bedrock Guardrails on every model call | yes | yes | yes | ✅ `guardrail` option | Nothing |
| Models through a Gateway inference target | yes | yes | yes | 🔧 OpenAI provider with the Gateway token as the key (cannot renew it); Anthropic through a loopback forwarder ([wso2/product-integrator#2573](https://github.com/wso2/product-integrator/issues/2573)) | Renewable auth in the model providers |
| Streaming model output | yes | yes | yes | ❌ | Streaming in `ai:ModelProvider` (see 3.1) |

### 3.5 Memory

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| AgentCore Memory, short term (events per session) | `MemoryClient`, session manager | advisors | `MemoryId`, automatic | ❌ we use DynamoDB instead | An `ai:ShortTermMemoryStore` backed by AgentCore Memory. The interface is public and can be implemented: get/put/remove of messages per key, plus `putCheckpoint` / `getCheckpoint` / `takeCheckpoint` for paused human approvals. A custom `ai:Memory` instead would lose durable approvals ([#2597](https://github.com/wso2/product-integrator/issues/2597)) |
| AgentCore Memory, long term (semantic, preference, summary, episodic) | yes | yes | not seen | ❌ | Retrieval of memory records, offered to the agent as context or as a tool |
| Memory with the execution role, no static key | yes | yes | yes | ❌ `ai.aws.dynamodb` needs an access key, so we keep one in Secrets Manager | `auth:DEFAULT_CREDENTIALS` in `ai.aws.dynamodb` ([#2835](https://github.com/wso2/product-integrator/issues/2835)), and in any AgentCore Memory store |
| Files kept across a session's stop and resume (managed session storage, preview) | n/a (platform) | n/a | n/a | ? not tried; needs no code change | Nothing for files. Not a home for conversation history: see the note below |

**What survives when a session's microVM stops.** RAM and every running process are lost,
so in-memory state ends with the microVM: `ai:ShortTermMemory` without a store, the cached
agent and the Gateway connection. Managed session storage (preview) keeps only **files**
under a mount path that starts with `/mnt`, for the **same session id**, and mounts them on
the new microVM at resume. AWS documents these limits: up to 1 GB per session, data deleted
after 14 days without an invocation, and a fresh, empty filesystem when the runtime version
changes. So every deployment of a new version would wipe it. It suits working files (a
coding agent's workspace), not conversation history or anything shared across sessions or
users. For those, use AgentCore Memory or a database.

**Stores Ballerina has today instead of AgentCore Memory.** Every one implements
`ai:ShortTermMemoryStore` (checkpoints included), so it drops into `new ai:ShortTermMemory(store)`
with no other change. All are short term only (conversation history per session).

| Package (cached version) | Backend on AWS | Auth | Network from AgentCore Runtime |
|---|---|---|---|
| `ballerinax/ai.aws.dynamodb` 1.1.0 (ours) | DynamoDB | static access key only ([#2835](https://github.com/wso2/product-integrator/issues/2835)) | public endpoint, works in PUBLIC mode |
| `ballerinax/ai.memory.redis` 1.2.0 | ElastiCache or MemoryDB | password in `redis:ConnectionConfig` | needs the runtime in VPC mode |
| `ballerinax/ai.memory.postgresql` 1.1.0 | RDS or Aurora PostgreSQL | user and password | needs VPC mode |
| `ballerinax/ai.memory.mssql` 1.4.1 | RDS SQL Server | user and password | needs VPC mode |

None of them gives what AgentCore Memory long term does (records extracted from the
conversation as facts, preferences and summaries). The password ones keep the password in
Secrets Manager, read with the execution role, as we do for the DynamoDB key. IAM database
auth (RDS, ElastiCache) was not found in these packages; not verified in depth.

Open question: where paused approvals (checkpoints) should live in AgentCore Memory.
Events carry metadata, which may be enough. Not verified.

### 3.6 Tools and the Gateway

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| Gateway tools over MCP | yes | yes | through the framework | 🔧 custom `GatewayToolKit` ([gateway_toolkit.bal](gateway_toolkit.bal)) | `ai:McpToolKit` that can send custom headers ([wso2/product-integrator#2823](https://github.com/wso2/product-integrator/issues/2823)) |
| Policy session header on every call (temporal Cedar policies) | yes | ? | ? | 🔧 same toolkit | Same fix |
| New token per invocation | yes | yes | ? | 🔧 same toolkit reconnects, because `notifications/initialized` cannot carry custom headers | A `ballerina/mcp` client that takes a token provider, so a token can change without reconnecting |
| Semantic tool search on the Gateway | Strands plugin | not seen | not seen | ? not tried | Probably usable as an ordinary Gateway tool; to verify |
| Code Interpreter | client | yes | API | ❌ | A client: start session, invoke (streamed results), stop |
| Browser | client | yes (Playwright) | API | ❌ | A client for sessions, plus browser automation over a SigV4-signed WebSocket. Hard: no Playwright for Ballerina; Java interop with Playwright for Java is one path |
| Web Search | client | not seen | not seen | ❌ | A client |
| Payments (x402) | yes | yes | not seen | ❌ | A client and a paying tool wrapper |
| Knowledge bases | client | not seen | not seen | ❌ | A client |
| Human approval before a tool runs | framework specific | ? | ? | ✅ `ai:RequiresApproval` gated tools | Nothing (this is ahead of the AWS SDKs) |

### 3.7 Observability

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| Traces to CloudWatch (X-Ray OTLP endpoint, SigV4 only) | ADOT, plus the managed collector on `localhost:4318` | ADOT; no managed collector | no managed collector | 🔧 a collector process in the container signs and forwards | A SigV4 OTLP exporter in `ballerina/otel` ([#2994](https://github.com/wso2/product-integrator/issues/2994)), or the managed collector for every entrypoint ([aws/agentcore-cli#1270](https://github.com/aws/agentcore-cli/issues/1270), open) |
| Resource identity from `OTEL_RESOURCE_ATTRIBUTES` | automatic | automatic | ? | 🔧 parsed in [start.sh](start.sh), applied by the collector | `ballerina/otel` should honour the standard `OTEL_RESOURCE_ATTRIBUTES` variable |
| Numeric token counts | yes | yes | ? | 🔧 collector converts strings to ints | A typed attribute API in `ballerina/observe` (today `addTagToSpan` takes strings only; [#2818](https://github.com/wso2/product-integrator/issues/2818)) |
| `gen_ai.usage.total_tokens` | yes | ? | ? | 🔧 collector sums the halves | Emit it in `ai.observe` |
| `session.id` on every span, through OTel baggage | yes | ? | ? | ❌ only the `invoke_agent` span, copied by the collector | Baggage propagation in `ballerina/otel` and `ballerina/ai`. This is what blocks tool-level evaluations (3.8) |
| Spans flushed before the container stops | yes | yes | ? | ❌ no flush or shutdown hook | [#2822](https://github.com/wso2/product-integrator/issues/2822) |
| One trace from the platform's invoke span into the agent | yes | ? | ? | ❌ the listener starts a new trace | Continue the incoming `traceparent` in the HTTP listener |

### 3.8 Evaluations

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| Spans recognised by Evaluations | listed framework | ? | ? | 🔧 collector renames scope `otel` to `opentelemetry.instrumentation.ballerina` | Emit a recognised scope name in `ballerina/otel` |
| Prompt and answer in the attributes Evaluations reads (`gen_ai.task.input`, `gen_ai.task.output`, `gen_ai.tool.call.arguments`, `gen_ai.tool.call.result`) | yes | ? | ? | 🔧 collector copies them | Emit the names from the OpenTelemetry GenAI conventions in `ai.observe` |
| Online evaluation, session and trace level | yes | ? | ? | ✅ with the rewrites above | Nothing more |
| Online evaluation, tool level | yes | ? | ? | ❌ fails with no diagnostic | `session.id` on every span (3.7) |
| Evaluation SDK (on-demand and batch runners, datasets, custom code evaluators, Ragas / DeepEval adapters) | yes | artifact exists, not checked | not seen | ❌ (WSO2 Integrator has its own evalsets, which do not talk to AgentCore Evaluations) | A client for AgentCore Evaluations, or an export from WSO2 evalsets into AgentCore datasets |

**WSO2 Integrator evaluations and AgentCore Evaluations do different jobs.**

| | WSO2 Integrator evaluations | AgentCore online evaluation |
|---|---|---|
| When | Before release, on a laptop or in CI (`bal test` through the Test Explorer) | After release, continuously, on sampled live traffic |
| Where the agent runs | In the test process, built from the project's code. Not on AgentCore Runtime | On AgentCore Runtime; scored from its traces in CloudWatch |
| Compared with | An evalset: approved conversations with the expected tool calls and answers | No expected answers; LLM judges score each session or trace |
| Checks | 23 templates, rule-based (for example Tool Trajectory) or LLM-as-judge, plus custom checks in the designer; a pass-rate threshold | Built-in evaluators (Correctness, Helpfulness, GoalSuccessRate and others) or your own judge or Lambda |
| Catches | Regressions caused by a change to instructions, tools or model | Quality drift and failures on real questions nobody anticipated |
| Tool-level checks for our agent | ✅ (Tool Trajectory compares tool calls directly) | ❌ (`session.id` gap, 3.7) |

Neither is required to deploy. Used together, they form the usual release practice: a gate
before release and monitoring after it. For a Ballerina agent the WSO2 evaluations matter
more, because they cover the tool-level checks AgentCore cannot run for us yet.

Points to settle before using WSO2 evaluations on this agent (not verified):
1. **Credentials in the test run.** Locally there is no Runtime, so no workload access
   token; the agent falls back to the Cognito client secret. Use a separate test client
   and keep its secret out of the repository.
2. **Real side effects and cost.** The replay calls the real Gateway tools and Bedrock. Run
   it against test backends, or mock tools that change data.
3. **One cached agent per process.** `agentFor` builds one agent and reuses it, so every
   thread in a run shares the first thread's policy session id. Temporal Cedar policies
   would count across threads.
4. **Discovery.** The evaluation's Agent node lists the project's agents, and evalset
   capture uses the Agent Chat panel on a chat service. Our agent is built inside a
   function and served on `/invocations`, so it may not be listed, and capture may not
   work. Hand-written evalsets (`tests/resources/evalsets/<name>.evalset.json`) are the
   fallback.

### 3.9 Configuration, deployment and testing

| Capability | Py | Java | .NET | Ballerina | What Ballerina needs |
|---|---|---|---|---|---|
| AgentCore CLI project templates (`agentcore create`, `add runtime --language`) | yes | ? | no (uses `dotnet aws deploy`) | ❌ container only, our own scripts in [deploy/](deploy) | A Ballerina template, or documented container steps (we have the latter) |
| Configuration bundles and experiments (read from baggage) | yes | not seen | not seen | ❌ | Baggage reading in the runtime context |
| Local emulator for tests | local run | ? | `AWS.AgentCore.Testing` | ❌ | A test helper that sends the AgentCore headers |
| Infrastructure as code (CDK, CloudFormation) | yes | yes | yes | ✅ language independent | Nothing |

---

## 4. What to build, in order

### P0: needed for a production agent on par with Python

1. **Runtime module.** A listener or service type for the HTTP contract: typed context,
   `/ping` with async task tracking, SSE, optional `/ws`, request and session ids in logs.
2. **Identity module.** M2M, API key, user federation (three-legged OAuth) and token
   exchange, built on a generated or hand-written client for the Identity data plane, with
   a local development fallback.
3. **AgentCore Memory store.** `ai:ShortTermMemoryStore` over AgentCore Memory events,
   including approval checkpoints, using the execution role.
4. **Upstream fixes.**
   - `ballerina/ai`: streaming agent runs; tokens supplied per invocation to toolkits.
   - `ballerina/mcp` and `ai:McpToolKit`: custom headers on every request, including
     notifications (#2823); a token provider instead of a fixed token.
   - `ballerina/otel` and `ballerina/observe`: SigV4 OTLP export, `OTEL_RESOURCE_ATTRIBUTES`,
     typed attributes, a recognised scope name, baggage propagation, continuing the
     incoming trace.
   - `ai.observe`: the OpenTelemetry GenAI attribute names Evaluations reads, and
     `total_tokens`.
   - `ballerinax/ai.aws.dynamodb`: the default credential chain.
   - Model providers: renewable auth for Gateway inference targets (#2573).

### P1: built-in tools and protocols

5. Code Interpreter client and agent tools.
6. Long-term memory retrieval.
7. AgentCore Evaluations client, or an evalset export.
8. A2A and AG-UI.
9. Browser client (needs a decision on browser automation, see 3.6).

### P2: the rest

10. Web Search, Payments, Knowledge bases, configuration bundles, semantic tool search.
11. AgentCore CLI template for Ballerina; a local emulator for tests.

### Foundation for all of the above

A generated Ballerina connector for the `bedrock-agentcore` (data plane) and
`bedrock-agentcore-control` APIs, the equivalent of layer 1. AWS publishes the API models
on Maven Central (`software.amazon.api.models:bedrock-agentcore` and
`bedrock-agentcore-control`), which could be a starting point for generation. Not tried.
Until then, each call can be a signed HTTP call as in [identity.bal](identity.bal).

---

## 5. A possible package shape

A proposal only. None of this exists.

```
ballerinax/aws.agentcore
  .runtime       listener, context, ping and async tasks, SSE, WebSocket
  .identity      M2M, API key, user federation, token exchange, local fallback
  .memory        ai:ShortTermMemoryStore over AgentCore Memory; long-term retrieval
  .tools         Code Interpreter, Browser, Web Search clients and ai tools
  .evaluations   evaluation and dataset clients
```

Plus the upstream fixes in section 4, which belong in the existing modules, not in a new
package.

---

## 6. Can a Ballerina agent go to production on AgentCore today?

For a defined scope, the evidence says yes. Whether that scope is enough is a decision for
the team, not something this document can settle. None of the gaps stops a
request-and-response agent that calls Gateway tools with its own (M2M) identity and uses
Bedrock models. Each gap rules out a particular use case, or adds code we have to maintain.

**What works today** (proven on our deployment): the Runtime contract; tokens from
AgentCore Identity (M2M) with no secret in the container; Gateway tools under Cedar policy,
including temporal policies; Bedrock models with guardrails; traces in CloudWatch; online
evaluations at session and trace level; conversation memory that survives a container
being replaced (DynamoDB).

**Use cases ruled out until the gaps close**

| Use case | Blocked by |
|---|---|
| Answers that stream word by word to a chat UI | No streaming in `ballerina/ai` |
| Acting as the signed-in user (their mailbox, their calendar) | No user federation (three-legged OAuth) |
| AgentCore Memory (long-term memory across sessions, managed by AWS) | No store; DynamoDB is our substitute |
| Background work after the response is sent | No `HealthyBusy`, so the session can go idle and stop mid-task |
| Tool-level quality scores | `session.id` only on the top span |
| Code Interpreter, Browser, A2A, AG-UI | No clients or servers yet |

**Risks to accept in writing**

1. **Workarounds we maintain.** The collector rewrites, `GatewayToolKit` and
   `identity.bal` copy what AWS's SDKs do. If AWS changes a header, an attribute name or a
   contract, no SDK update fixes it for us; we have to notice and fix it ourselves.
2. **A static key for memory.** `ai.aws.dynamodb` needs an access key (kept in Secrets
   Manager, scoped to one table) instead of the execution role
   ([#2835](https://github.com/wso2/product-integrator/issues/2835)).

**Most critical problems, ranked**

The gaps themselves, with library code, workarounds and issue links, are in
[GAPS.md](GAPS.md).

| # | Problem | Why it is critical | Fix |
|---|---|---|---|
| 1 | Static access key for memory | A long-lived key to rotate and protect, instead of the execution role | [#2835](https://github.com/wso2/product-integrator/issues/2835): default credentials in `ai.aws.dynamodb`, or an AgentCore Memory store |
| 2 | Spans lost when the container stops | The last spans of a session can be lost, and with them what Evaluations scores | [#2822](https://github.com/wso2/product-integrator/issues/2822) |
| 3 | The agent can reach more than the Gateway | Model calls go straight to Bedrock and in-agent tools run locally, both outside Cedar; with public networking nothing stops other outbound calls | VPC with outbound limited to the Gateway and required AWS services; keep risky tools behind the Gateway |
| 4 | Workarounds that fail silently | If the collector dies, the agent keeps serving and traces simply stop; an AWS change can break the collector rewrites, `GatewayToolKit` or `identity.bal` with no warning | An alarm on missing traces; tests that run the rewrites; upstream fixes (section 4) |
| 5 | Policy decisions in CloudWatch not verified | We describe the Gateway's decisions as part of the record, but have not confirmed they arrive | Check the Gateway's logs for allow and deny entries |
| 6 | Releases reach every user at once | The `DEFAULT` endpoint follows the latest version | Dedicated endpoints pinned to a tested version |
| 7 | Missing capabilities: streaming, acting as the user, AgentCore Memory, tool-level scores | They rule out use cases, not production | Section 4, P0 |

Not gaps: Gateway tokens come from AgentCore Identity (proven), so the agent holds no
client secret. Cleanup only: delete the old client-secret fallback in
[agents.bal](agents.bal), and rotate any secret that was ever in an old runtime version's
environment variables.

**Production work for any language** (not Ballerina gaps, but still needed): dedicated
endpoints instead of `DEFAULT`; a VPC with outbound traffic limited to the Gateway and the
AWS services the agent needs; alarms on errors, latency and token use; quotas checked
against expected load; rotation of every secret that has ever sat in a runtime's
environment variables.

---

## 7. Other hosting platforms (ECS, EKS, EC2, Lambda)

Most gaps are in Ballerina's **libraries**, so they follow the agent to any platform. The
AgentCore services (Gateway, Identity, Memory, Observability, Evaluations) can be used from
an agent that runs outside AgentCore Runtime, so the same gaps still apply. Moving
platforms changes which ones matter:

| Gap | On AgentCore Runtime | On ECS, EKS or EC2 |
|---|---|---|
| Runtime contract, `/ping`, context headers | Small, already solved | Gone: an ordinary HTTP service, which Ballerina handles well |
| `HealthyBusy` for background work | Needed | Gone: you control the container's life |
| Streaming | Needed | Still needed |
| Identity | Runtime hands us the workload access token | Bigger gap: the agent must get the workload access token itself (`GetWorkloadAccessToken` and variants), so more code to write |
| Memory | Same gap | Same gap |
| Trace export | A collector process inside our container | Easier: a normal collector sidecar (ECS task, Kubernetes pod) |
| Attribute fixes for CloudWatch and Evaluations | Needed | Still needed if you want AgentCore Observability and Evaluations |
| Session isolation | AWS gives each session its own microVM | Yours to build. Our agent caches **one agent per container** with a fixed policy session id ([agents.bal](agents.bal)), which is only correct because AgentCore gives each session its own container. On ECS one container serves many sessions, so this design would mix sessions and must change before moving |
| Scaling, patching, idle shutdown | Managed | Yours to run |

Python, Java and .NET also have extra work outside AgentCore Runtime (session isolation,
scaling), but their SDK features work there too. For Ballerina, the library gaps stay on
every platform, and the platform work is added on top.

---

## 8. Open questions

1. Does Spring AI AgentCore cover the Gateway, policy session header, A2A and observability?
   (Its README did not mention them.)
2. What do `spring-ai-agentcore-evaluations` and `spring-ai-agentcore-otel-extension`
   contain?
3. Does the .NET hosting library handle `/ping`, `HealthyBusy`, Identity and tracing? (The
   blog post did not cover them.)
4. Can paused approvals be stored as AgentCore Memory events?
5. Can the AgentCore CLI deploy a prebuilt container for a language it has no template for?
6. Can the Gateway's semantic tool search be used from Ballerina as an ordinary tool?
7. Can a Ballerina connector be generated from AWS's published API models?
8. Is managed session storage's 1 GB, 14-day, wiped-on-new-version behaviour still the
   same when it leaves preview?

---

## Sources

- [aws/bedrock-agentcore-sdk-python](https://github.com/aws/bedrock-agentcore-sdk-python) (source tree, `runtime/app.py`, `identity/auth.py`)
- [aws/bedrock-agentcore-sdk-typescript](https://github.com/aws/bedrock-agentcore-sdk-typescript)
- [spring-ai-community/spring-ai-agentcore](https://github.com/spring-ai-community/spring-ai-agentcore)
- [Spring AI SDK for Amazon Bedrock AgentCore is now Generally Available](https://aws.amazon.com/blogs/machine-learning/spring-ai-sdk-for-amazon-bedrock-agentcore-is-now-generally-available/)
- [Building and Deploying .NET AI Agents with Amazon Bedrock AgentCore](https://aws.amazon.com/blogs/developer/building-and-deploying-net-ai-agents-with-amazon-bedrock-agentcore/)
- [AWSSDK.BedrockAgentCore on NuGet](https://www.nuget.org/packages/AWSSDK.BedrockAgentCore/4.0.2)
- [software.amazon.awssdk:bedrockagentcore on Maven Central](https://central.sonatype.com/artifact/software.amazon.awssdk/bedrockagentcore)
- [Managed session storage launch](https://aws.amazon.com/about-aws/whats-new/2026/03/bedrock-agentcore-runtime-session-storage/) and [Persist session state with filesystem configuration](https://aws.amazon.com/blogs/machine-learning/persist-session-state-with-filesystem-configuration-and-execute-shell-commands/)
- [HTTP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-http-protocol-contract.html)
- [Pass custom headers to AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-header-allowlist.html)
- [Evaluations: supported frameworks](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks.html) and [generic framework support](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-generic.html)
- `ballerina/ai` 1.16.0 source in the WSO2 Integrator app bundle (`agent.bal`, `model-provider.bal`, `short_term_memory_store.bal`, `token.bal`, `tool.bal`)

---

## Change log

| Date | Change |
|---|---|
| 2026-10-28 | First version: three layers, per-language inventory, feature tables, priorities, open questions |
| 2026-10-29 | Added managed session storage (3.5), production readiness (6), other hosting platforms (7) |
| 2026-10-29 | Added WSO2 Integrator evaluations compared with AgentCore Evaluations (3.8) |
| 2026-10-29 | Added the ranked list of most critical problems (6) |
| 2026-10-29 | Identity is not a gap: removed the secret items from the critical list; linked GAPS.md and the filed issues |
| 2026-11-03 | Listed the Ballerina memory stores usable instead of AgentCore Memory (3.5) |
