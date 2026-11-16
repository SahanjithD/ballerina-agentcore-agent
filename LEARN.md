# Understanding what we built, from the ground up

How to use this file:

1. Read it in order. Each part needs the one before it.
2. Keep the code open beside it. Every idea points to a real file in this repo.
3. At each **Checkpoint**, answer out loud without looking. If you can't, reread that part.
4. Keep three lists while you read: **facts** (how AWS works), **choices** (what we decided),
   **open questions** (what we haven't proven). Part 6 has mine; compare at the end.

Time: about 2 to 3 hours for a careful first pass.

---

## Part 1. Fundamentals

### 1.1 A model is not an agent

A large language model (LLM) is a function: **text in, text out**. It cannot click, call an
API, or remember anything between calls. Every call, you send it the whole conversation
again.

### 1.2 An agent is a loop around a model

An agent is ordinary code that runs this loop:

```
1. Send the model: instructions + conversation so far + a list of tools it may use
2. The model answers with EITHER
     a) a final answer            -> return it to the user, stop
     b) "call tool X with {args}" -> go to 3
3. The code runs tool X, adds the result to the conversation, goes back to 1
```

The model only **chooses**. The code **acts**. In our repo, `ai:Agent` from `ballerina/ai`
is that loop: see `buildAgent` in [agents.bal](agents.bal) (the `new ai:Agent(...)` at the end).

The pieces the loop needs, and where they are in our agent:

| Piece | What it is | Ours |
|---|---|---|
| Instructions | The system prompt: role and rules | `systemPrompt` in `buildAgent` |
| Model | Who decides | Amazon Nova Lite on Bedrock |
| Tools | Functions the model may ask for | `sum`, `multiply`, `whereAmIRunning` (local) + Gateway tools (remote) |
| Memory | Where the conversation is kept between turns | `ai:ShortTermMemory` (in the container, or DynamoDB) |

### 1.3 A tool is a function with a description

To the model, a tool is just: a **name**, a **description**, and a **JSON schema** of its
inputs. The model reads these and decides. Example: `sum(int a, int b)` in
[agents.bal](agents.bal) becomes `{"name":"sum","parameters":{"a":int,"b":int}}`.

Two kinds of tools:
- **Local tools** run inside the agent's own process (`@ai:AgentTool` functions).
- **Remote tools** run in another service. The agent calls them over the network.

### 1.4 MCP: a standard way to offer remote tools

**Model Context Protocol (MCP)** is a protocol so any agent can use any tool server. It is
JSON messages over HTTP. Three messages matter:

| Message | Meaning |
|---|---|
| `initialize` | "Hello, let's start a session" |
| `tools/list` | "What tools do you have?" (returns names, descriptions, schemas) |
| `tools/call` | "Run tool X with these arguments" |

An **MCP server** offers tools ([tools/mcp-server/service.bal](tools/mcp-server/service.bal)
offers `countWords` and `whoAmI`). An **MCP client** uses them (our `GatewayToolKit` in
[gateway_toolkit.bal](gateway_toolkit.bal)). Why it matters: a tool built once as an MCP
server works with Ballerina agents, Strands agents, Claude, anything that speaks MCP. That is
the whole "build once, use from every agent" argument in the article.

### 1.5 Containers

A container image packages your program and everything it needs to run. AWS runs the image;
you don't manage servers. Our image is built from the [Dockerfile](Dockerfile).

AgentCore Runtime takes an agent in one of two forms: a **container image from ECR** (ours)
or a **code zip from S3** (Python, with templates such as Strands). It speaks one of four
**protocols**: HTTP, MCP, A2A (agent to agent) and AG-UI (streaming to a user interface).
We use two:

- **HTTP protocol** (our agent): listen on port 8080, `GET /ping` for health, `POST /invocations` for work. See [service.bal](service.bal).
- **MCP protocol** (our MCP server): listen on port 8000 at `/mcp`.

### 1.6 Identity: the most important fundamental here

Almost every confusion in this project is about identity. Two words first:

- **Authentication**: *who are you?* (prove it)
- **Authorization**: *what may you do?* (a rule decides)

This system uses **two different identity worlds**. Learn to tell them apart.

**World A: AWS IAM** (how anything talks to an AWS API)

- An **IAM role** is an identity with permissions, but no password. A trusted service
  *assumes* it and gets **temporary credentials** (access key starting `ASIA`, a secret, a
  session token) that expire and renew automatically.
- Requests to AWS APIs are **signed with SigV4**: the secret is used to compute a signature
  over the request. **The secret itself is never sent.** AWS recomputes the signature to check it.
- An **IAM policy** says which actions on which resources the role may perform.
- Inside AgentCore Runtime, our container gets the role's temporary credentials from a
  local metadata address (`169.254.169.254`, called MMDS). `auth:DEFAULT_CREDENTIALS` in
  [agents.bal](agents.bal) finds them there. That is why the agent needs no AWS keys.

**World B: OAuth 2.0 tokens** (how our agent talks to the Gateway)

- A **client** (our agent) has a **client id + client secret**, issued by an
  **authorization server** (Amazon Cognito here).
- **Client-credentials flow**: the client sends id + secret to Cognito's token URL and gets
  an **access token**, a **JWT**: a signed JSON document saying who it is for and when it
  expires (1 hour here).
- It is a **bearer token**: *whoever holds it can use it*. So it must be short-lived and
  never logged.
- The receiver (the Gateway) checks the JWT's signature against Cognito's public keys. No
  call to Cognito needed.

| | IAM (World A) | OAuth (World B) |
|---|---|---|
| Proof sent on the wire | A signature (secret stays home) | The token itself |
| Lifetime | Temporary, auto-renewed | 1 hour, must be fetched again |
| Used for | Bedrock, Identity, CloudWatch, Gateway to tools | Agent to Gateway |

### 1.7 Traces

A **trace** is the record of one request: a tree of timed steps called **spans** ("model
call took 800 ms", "tool call `whoAmI`", "HTTP POST to Gateway"). **OpenTelemetry (OTel)** is
the standard format. Our container runs an OTel collector beside the agent
([otel-collector.yaml](otel-collector.yaml), [start.sh](start.sh)) that ships spans to CloudWatch.

### Checkpoint 1
1. The model said "call `sum` with a=2, b=3". Who actually adds the numbers?
2. Why doesn't the agent need an AWS access key in its config?
3. What is the difference between sending a SigV4 signature and sending a bearer token?
4. Name the three MCP messages and what each does.

---

## Part 2. The problem AgentCore solves

Running one agent on your laptop is easy. Running agents for a company raises five questions:

| Question | Without a platform you'd build... | AgentCore piece |
|---|---|---|
| **Where does it run**, safely, at scale, isolated per user? | Servers, scaling, isolation | **Runtime** |
| **How does it reach tools**, without each agent wiring every system? | Per-agent connections | **Gateway** |
| **Who is it**, and how does it get credentials without holding secrets? | Secrets in config files | **Identity** |
| **What may it do**, enforced outside the agent? | Checks inside each tool | **Policy** |
| **What did it do**, and was it good? | Custom logging | **Observability**, **Evaluations** |

AgentCore has more than these. The console also lists Memory, Browser, Code Interpreter,
Knowledge Bases, Payments, Registry, Harness (managed Strands agents), Capacity providers and
Optimisations. We used none of them except a Harness test.

### 2.1 Runtime

- Hosts your agent. Called with the `InvokeAgentRuntime` API, authenticated by **IAM or
  JWT** (you pick one per runtime). Ours uses IAM.
- **Compute type**, fixed at creation:
  - **microVMs** (ours): each **session id** gets its **own microVM**. Same session id =
    same microVM = same RAM. Different session = fully separate. Pay per use.
  - **Instances**: AWS-managed EC2 through a capacity provider, for multi-day sessions,
    full OS access or GPUs.
- **Lifecycle**: a session stops after an **idle timeout** (default 15 minutes) and has a
  **maximum lifetime** (default 8 hours). Both are configurable up to 14 days. We kept
  the defaults.
- **Filesystem** (optional): managed session storage, S3 Files or EFS keep files across a
  session's stop and resume. Without it, everything in the microVM is lost when it stops.
- **Network**: Public (internet access, ours) or VPC.
- **Versions and endpoints**: every update makes a new version. The **default endpoint**
  follows the latest version and is meant for development; production should call a
  **dedicated endpoint** pinned to a tested version.
- Gives the container an **execution role** (World A credentials).

### 2.2 Gateway

One MCP endpoint in front of many tool backends, called **targets**.

```
agent --(MCP, bearer token)--> Gateway --> target 1: our MCP server (on Runtime)
                                       --> target 2: our REST API (on Lambda)
```

- **Inbound auth**: who may call the Gateway. Ours: Cognito JWT (World B).
- **Outbound auth**: how the Gateway calls each target. Ours: the Gateway's own IAM role,
  SigV4 (World A).
- It turns a REST API into MCP tools from its OpenAPI spec
  ([gateway/tools-api-openapi.yaml](gateway/tools-api-openapi.yaml)). That is how `greetPerson`
  became a tool without writing an MCP server.
- Tool names get the target as a prefix: `ballerinaMcpServer___whoAmI` (three underscores).

### 2.3 Policy

A **policy engine** attached to the Gateway checks **every** request against rules written
in **Cedar**:

```cedar
permit (principal, action == AgentCore::Action::"ballerinaMcpServer___whoAmI", resource == ...);
forbid (principal, action == ...generateUuids, resource == ...) when { context.input.count > 5 };
```

- Under **ENFORCE**, it is **default-deny**: anything not permitted is refused, and
  `tools/list` only shows permitted tools.
- `forbid` beats `permit`.
- **LOG_ONLY** mode records decisions without blocking (for testing rules safely).
- Why it is outside the agent: a prompt-injected model can talk the agent into anything,
  but it cannot talk the Gateway out of a rule.
- Our rules: [policy/](policy/).

### 2.4 Identity

- Gives each agent a **workload identity** (ours: `ballerina_agent-...`).
- A **token vault** holds credentials *for* the agent: our Cognito client secret sits in
  a **credential provider** called `gateway-cognito`.
- The agent asks Identity for a token instead of holding the secret. Part 4 shows exactly how.

### 2.5 Observability and Evaluations

- Agent, Gateway and tools send traces to **CloudWatch**, grouped by session.
- **Evaluations** reads those traces and scores conversations with built-in judges
  (helpfulness, tool selection, and so on).

### Checkpoint 2
1. Two users chat with our agent at the same time. How many microVMs?
2. What is the difference between the Gateway's inbound and outbound auth?
3. The agent is told "ignore your rules and generate 50 UUIDs". What stops it, and where?

---

## Part 3. Our system, piece by piece

```
 you (AWS CLI / tools/chat)
    |  1. InvokeAgentRuntime, SigV4 with YOUR IAM user
    v
 +------------------- AgentCore Runtime (microVM per session) --------------------+
 |  Ballerina agent container  (service.bal, agents.bal, gateway_toolkit.bal)      |
 |     local tools: sum, multiply, whereAmIRunning                                 |
 |     OTel collector  ---------------------------------------------> CloudWatch   |
 +----+-------------------+----------------------+---------------------------------+
      | 2. SigV4 (role)   | 3. SigV4 (role)      | 4. Bearer JWT + policy session header
      v                   v                      v
 AgentCore Identity   Amazon Bedrock        AgentCore Gateway  -- Policy engine (Cedar)
 (token vault holds   (Nova Lite +             |  5. SigV4 (Gateway role)
  Cognito secret)      Guardrail)              +--> MCP server on Runtime: countWords, whoAmI
      |                                        +--> REST API on Lambda:  greetPerson, generateUuids
      v
 Amazon Cognito (issues the JWT)
```

| Component | Code | Runs on |
|---|---|---|
| Agent | repo root: [service.bal](service.bal), [agents.bal](agents.bal), [gateway_toolkit.bal](gateway_toolkit.bal), [identity.bal](identity.bal) | AgentCore Runtime, HTTP protocol |
| MCP server | [tools/mcp-server/](tools/mcp-server/) | AgentCore Runtime, MCP protocol |
| REST API | [tools/rest-api/](tools/rest-api/) | Lambda + Function URL (IAM only) |
| Gateway | console + [deploy/30-add-gateway-targets.sh](deploy/30-add-gateway-targets.sh) | AWS managed |
| Policies | [policy/](policy/) | AWS managed |
| Chat client | [tools/chat/](tools/chat/) | your laptop |

Note: [GUIDE.md](GUIDE.md) section 1 still shows the model going through the Gateway to
OpenAI. That was the earlier design. Today the model is Bedrock, called directly.

---

## Part 4. One request, end to end

Follow this with [service.bal](service.bal) open. The user asks *"who am I talking to? use whoAmI"*.

**Step 1. You invoke the Runtime.**
`aws bedrock-agentcore invoke-agent-runtime --runtime-session-id S --runtime-user-id U ...`
Your CLI signs it with your IAM user (World A). AWS checks you may `InvokeAgentRuntime`,
and, because you named a user, `InvokeAgentRuntimeForUser`.

**Step 2. The Runtime routes it.**
Session `S` has no microVM yet, so one starts and runs our container. Runtime sends
`POST /invocations` with headers:
- `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: S`
- `WorkloadAccessToken: <WAT>`. A short-lived token that says "this is workload
  `ballerina_agent`, acting for user `U`". **It only comes because you passed a user id.**

**Step 3. The agent gets a Gateway token from Identity** (`identityToken` in
[agents.bal](agents.bal) calls `gatewayTokenFromIdentity` in [identity.bal](identity.bal)).

```
agent --POST /identities/oauth2/token-------------------------> AgentCore Identity
        body: provider "gateway-cognito", flow M2M, the WAT
        signed with SigV4 using the execution role
                                   Identity checks: is the WAT valid? may this role
                                   use this provider? (IAM policy gateway_token_from_identity)
                                   Identity takes the Cognito secret from its vault ---> Cognito
                                   Cognito returns a JWT (1 hour) <----------------------
agent <-- {accessToken: JWT} -----------------------------------
```

The agent never sees the Cognito secret. It proved who it is with two things: the WAT
(from Runtime) and its role signature (from IAM).

**Step 4. First invocation in this microVM: build the agent** (`agentFor`, `buildAgent`).
- `GatewayToolKit` connects to the Gateway: `initialize`, then `tools/list`, each with
  `Authorization: Bearer JWT` and `x-amzn-bedrock-agentcore-policy-session-id: S`.
- The Gateway checks the JWT (inbound auth), then Policy filters the list. Under our
  enforce rules the agent sees only `whoAmI` and `greetPerson`.
- The Bedrock model provider is created with `auth:DEFAULT_CREDENTIALS` (the role).
- The agent is cached for the life of the microVM (`cachedAgent`).

**Step 5. The loop runs** (`agent.run(...)` in [service.bal](service.bal)).
1. **Model call**: agent to Bedrock `Converse`, SigV4 with the role. The Guardrail screens
   input and output. The model replies "call `ballerinaMcpServer___whoAmI`".
2. **Tool call**: `GatewayToolKit.callTool` takes **this invocation's** JWT from the
   `ai:Context` and sends `tools/call` to the Gateway.
3. **Gateway**: checks the JWT, asks Policy "may this caller run `whoAmI` with these
   inputs?" Permit. Calls the MCP server target, **signing with the Gateway's own IAM
   role**. The MCP server runs `whoAmI` and replies. Guardrail policies may inspect or
   suppress the output (ours suppresses names in `greetPerson` output).
4. Result goes back to the model. The model writes the final answer.

**Step 6. The response** returns to you. Traces from the agent, Gateway and MCP server land
in CloudWatch under the session.

**Second message, same session `S`**: same microVM, cached agent, memory still holds turn 1.
A **fresh** WAT arrives, so a fresh JWT is fetched (step 3) and handed to the toolkit through
`ai:Context`. That is why the agent keeps working past the token's 1 hour life.

### 4.1 The credential map (memorize this table)

| Hop | Proof used | Where the secret lives | Expires |
|---|---|---|---|
| You to Runtime | SigV4, your IAM user | Your laptop | Your session |
| Runtime to agent | (internal) + WAT handed over | AWS | Per invocation |
| Agent to Identity | SigV4 (execution role) + WAT | Role creds from MMDS, never stored | Auto-renewed |
| Identity to Cognito | Client id + secret | **Identity token vault** | Long-lived (rotate it) |
| Agent to Gateway | Bearer JWT | Agent memory only | 1 hour |
| Gateway to MCP server / Lambda | SigV4, Gateway role | AWS | Auto-renewed |
| Agent to Bedrock | SigV4 (execution role) | MMDS | Auto-renewed |
| Collector to CloudWatch | SigV4 (execution role) | MMDS | Auto-renewed |

**Result: the agent container holds no long-lived secret.** The only long-lived secret in
the whole system is the Cognito client secret, and it lives in the vault.

### 4.2 The session id does three jobs

One value, `S`, ties together:
1. **The microVM** (Runtime: same session, same machine).
2. **Memory** (`agent.run(..., sessionId = session)`).
3. **The policy session** (the header the toolkit sends, so the Gateway can apply rules
   across calls in one conversation, such as "at most 3 refunds per session").

### Checkpoint 4
1. You invoke **without** `--runtime-user-id`. What header is missing, and what does our
   agent do then? (Hint: `gatewayToken` in [agents.bal](agents.bal).)
2. Which identity does the Gateway use to call the MCP server: the agent's or its own?
3. Where is the Cognito client secret, and who can read it?
4. Why do we fetch a new JWT on every invocation instead of once?
5. A tool call is denied. Which component decided, and where would you see why?

---

## Part 5. Why each piece is the way it is

| Decision | Why | What it costs |
|---|---|---|
| Build the agent on the **first invocation**, not at startup | The WAT only exists inside an invocation | First message is slower |
| **Custom `GatewayToolKit`** instead of `ai:McpToolKit` | The built-in one can't send custom headers (issue #2823) or swap tokens | Our own code to maintain |
| Token in the client's `auth`, reconnect on a new token | MCP's `notifications/initialized` carries no custom headers, and the Gateway answers it 401 without a token | One reconnect per new token |
| **Bedrock called directly**, not through the Gateway | No token expiry, no provider key, Guardrails apply | Model calls are invisible to Cedar policy |
| **Identity M2M** instead of a client secret in config | No secret in the container | Every invocation must carry a user id |
| MCP server on **Runtime**, REST API on **Lambda** | To show both target types work | Two hosting models to understand |
| Memory in **DynamoDB** (Ballerina store), not AgentCore Memory | Ballerina has no AgentCore Memory client | A separate table and access key (now turned off) |

---

## Part 6. Is this the correct architecture?

Split the question into three, and be honest about each.

### 6.1 Facts: what AWS designed AgentCore for, and we follow
- Agent hosted on **Runtime**, tools behind a **Gateway**, rules in **Policy** on the
  Gateway, credentials through **Identity**, traces to **CloudWatch**. This is AWS's
  intended shape, and ours matches it.
- Tools as **MCP** (or REST turned into MCP by the Gateway). Standard.

### 6.2 Choices: reasonable, but other answers exist

| Our choice | Alternative | When the alternative is better |
|---|---|---|
| Model direct to Bedrock | Model through the Gateway | Security wants one policy language for models and tools |
| Gateway inbound auth = Cognito JWT | Gateway inbound auth = IAM (worth checking in AWS docs) | No Cognito to run; but our MCP client can't SigV4-sign today |
| MCP server on Runtime | Lambda, ECS, or anywhere reachable | Stateless tools: Lambda is simpler and cheaper |
| Some tools local in the agent | Everything behind the Gateway | Anything touching data or money must be behind the Gateway |
| One agent per microVM, tools listed once | Re-list tools per invocation | Tool permissions change during a session |

### 6.3 Open questions: not proven yet
1. **Temporal policies**: the policy session header is sent, but no temporal rule was
   tested on AWS.
2. **Policy decisions in CloudWatch**: assumed, not seen by us.
3. **Acting for a real user** (user signs in, agent uses *their* access): not supported in
   Ballerina yet. Our "user id" is just a label for the WAT.
4. **Network lockdown**: the agent can reach the internet directly. Production should use a
   VPC so the Gateway and needed AWS services are the only way out.
5. **Old secret exposure**: the Cognito secret is in plain text in runtime versions 45 to
   47. Rotate it.
6. **Default endpoint in use**: we invoke the development endpoint that follows the latest
   version. Production needs a dedicated endpoint pinned to a tested version.
7. **This guide was partly outdated** before it was checked against the live console and
   CLI. Anything not yet verified against the account is marked as such.

So the honest answer: **the shape is AWS's recommended one; the details are defensible
choices with known trade-offs; several things are still open.** That is a normal state for
a proof of concept, as long as you say it.

---

## Part 7. How to make it stick

1. **Trace one real request.** Invoke the agent once, then open CloudWatch, find the
   session, and match every span to a step in Part 4. (I'll ask before running anything
   against AWS.)
2. **Break it on purpose, in your head.** For each row of the table in 4.1, ask: "if this
   credential leaked or expired, what fails and who is affected?"
3. **Explain it back.** Tell me Part 4 in your own words and I'll point out gaps. Then let
   me quiz you on the checkpoints.

## Glossary

| Term | One line |
|---|---|
| Agent | Code that loops: ask model, run chosen tool, repeat |
| Cedar | AWS's policy language: `permit` / `forbid` rules |
| Credential provider | An entry in the Identity vault holding a secret for agents to use |
| Execution role | The IAM role the Runtime gives our container |
| Guardrail | Bedrock feature that screens model input and output |
| JWT | Signed token with claims (who, what for, expiry) |
| M2M | Machine-to-machine OAuth: the agent acts as itself, not as a user |
| MCP | Standard protocol for agents to list and call tools |
| microVM | Small isolated VM; one per Runtime session |
| MMDS | Metadata address inside the microVM that hands out role credentials |
| SigV4 | AWS request signing; the secret never leaves |
| Span / trace | One timed step / the tree of steps for a request |
| Target | One tool backend behind the Gateway |
| WAT | Workload access token: Runtime's proof of "this agent, for this user, now" |
