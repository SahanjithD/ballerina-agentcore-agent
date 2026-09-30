import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/ai.openai;

configurable openai:OPEN_AI_MODEL_NAMES modelType = openai:GPT_4_1;

// Route model calls through the Gateway's inference target rather than straight to
// api.openai.com. The Gateway then governs the model conversation the same way it
// already governs tool calls -- Cedar policy and Bedrock Guardrails apply to every model
// call -- and it holds the OpenAI key in the token vault, so the agent never sees it.
//
// Ends in `/v1`: the provider posts to `{serviceUrl}/chat/completions`, and the Gateway
// serves the OpenAI Chat Completions API at `/inference/v1/chat/completions`.
configurable string inferenceUrl =
    "https://ballerina-agent-gatewa-01gzl3luj1.gateway.bedrock-agentcore.us-east-1.amazonaws.com/inference/v1";

// An AgentCore Gateway -- or any MCP server -- speaking streamable HTTP. Its tools are
// discovered at startup and offered to the agent alongside the local ones below.
// Leave empty to run with local tools only.
configurable string mcpServerUrl = "https://ballerina-agent-gatewa-01gzl3luj1.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp";

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
# agent itself; `ballerinaMcpServer___whoAmI` runs in a separate container behind the
# Gateway. Asking both in one conversation is the cheapest way to see the difference --
# in the trace the local call is a bare `execute_tool` span with no HTTP beneath it,
# while the Gateway one carries a whole client stack and the Gateway's own spans.
#
# + return - Identity of the agent process
@ai:AgentTool
isolated function whereAmIRunning() returns AgentIdentity => {
    servedBy: "ballerina-agent, in-process @ai:AgentTool",
    language: "Ballerina 2201.13.5 (Swan Lake Update 13)",
    utcTime: time:utcToString(time:utcNow())
};

# Mints a Gateway access token with the Cognito client credentials held in configuration.
# Only used when AgentCore Identity is not configured or the Runtime supplied no workload
# access token (see `identity.bal`).
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

# Picks where the Gateway token comes from. AgentCore Identity when it is configured and
# the Runtime passed a workload access token; otherwise a static token, then the client
# secret -- the fallbacks exist so the agent still runs when invoked without a user id.
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
# Built on the first invocation rather than at startup, because the workload access token
# only exists per request. AgentCore gives each session its own container, so one agent per
# container is one agent per session. The token is not renewed (the OpenAI provider takes a
# fixed key), so a session outliving the token's hour fails its model calls.
#
# + token - A Gateway bearer token
# + return - The agent, or an error if the Gateway cannot be reached
isolated function buildAgent(string token) returns ai:Agent|error {
    // `ai:McpToolKit` calls `listTools` in its `init`, so the Gateway's (policy-filtered)
    // tool list is fixed when the agent is built.
    ai:McpToolKit gateway = check new (mcpServerUrl, auth = {token});

    // The OpenAI provider sends its key as `Authorization: Bearer`, which is what the
    // Gateway's CUSTOM_JWT authorizer reads.
    ai:ModelProvider model = check new openai:ModelProvider(token, modelType, inferenceUrl);

    // A plain literal for `tools`, so the Ballerina visual editor can display every tool.
    return check new ai:Agent(
        systemPrompt = {
            role: "Assistant",
            instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
        }, memory = (), model = model, tools = [sum, multiply, whereAmIRunning, gateway]
    );
}

isolated ai:Agent? cachedAgent = ();

# Returns this container's agent, building it on first use.
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
