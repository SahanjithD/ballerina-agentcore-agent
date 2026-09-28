import ballerina/ai;
import ballerina/http;
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

// Ballerina's HTTP client fetches a token from `tokenUrl` and renews it before expiry, so
// nothing here goes stale. Scopes are omitted deliberately: Cognito then grants every scope
// the client is allowed, which avoids depending on the exact resource-server prefix.
final http:OAuth2ClientCredentialsGrantConfig? oauthAuth = mcpTokenUrl == "" ? ()
    : {tokenUrl: mcpTokenUrl, clientId: mcpClientId, clientSecret: mcpClientSecret};

final http:BearerTokenConfig? tokenAuth = mcpAuthToken == "" ? () : {token: mcpAuthToken};

// OAuth2 wins when both are supplied.
final http:ClientAuthConfig? gatewayAuth = oauthAuth ?: tokenAuth;

# Mints a Gateway access token with the same Cognito client credentials the MCP toolkit
# uses.
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

// `openai:ModelProvider` sends its key as `Authorization: Bearer`, which is exactly what the
// Gateway's CUSTOM_JWT authorizer reads, so the Gateway token goes in as the "API key" and
// needs no translation. (`anthropic:ModelProvider` hardcodes `x-api-key` and needed a
// loopback forwarder for the same job.)
//
// The token is minted once, at startup, and Cognito issues one-hour tokens: the provider's
// auth is fixed to a static token, so it cannot renew one. A container that lives past an
// hour will start failing model calls.
final ai:ModelProvider model =
    check new openai:ModelProvider(check mintGatewayToken(), modelType, inferenceUrl);

// Connects at startup: `ai:McpToolKit` calls `listTools` in its `init`, so the tool list is
// fixed once the agent is built. An unreachable Gateway therefore stops the container from
// starting rather than silently serving an agent that is missing half its tools.
//
// Not optional, deliberately. The Ballerina visual editor renders the agent's tools only
// when `tools` below is a plain array literal; a conditional expression leaves the node
// blank. Making the toolkit unconditional is what keeps the literal, at the cost of the
// old `mcpServerUrl = ""` path that ran with local tools only. That path existed for local
// testing, and losing it is consistent with the fail-fast behaviour described above --
// there is no longer a way to boot without a reachable Gateway.
final ai:McpToolKit gateway = check new (mcpServerUrl, auth = gatewayAuth);

final ai:Agent assistantAgent = check new (
    systemPrompt = {
        role: "Assistant",
        instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
    }, memory = (), model = model, tools = [sum, multiply, whereAmIRunning, gateway]
);

