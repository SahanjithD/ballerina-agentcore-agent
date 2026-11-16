import ballerina/ai;
import ballerina/mcp;

// The Gateway groups requests carrying the same value into one policy session, the
// boundary Cedar temporal policies are evaluated over ("at most 3 refunds per session",
// "run tests before deploy"). Once the policy engine holds a temporal policy, a request
// without it fails validation -- `initialize` and `tools/list` included.
const POLICY_SESSION_HEADER = "x-amzn-bedrock-agentcore-policy-session-id";

// `ai:Context` key under which an invocation hands the toolkit its Gateway token.
const GATEWAY_TOKEN_KEY = "gatewayToken";

# An MCP toolkit for AgentCore Gateway that sends the policy session id on every request,
# and, with AgentCore Identity, the current invocation's Gateway token.
# `ai:McpToolKit` cannot send custom headers (wso2/product-integrator#2823), so this is the
# toolkit WSO2 Integrator generates from `ai:McpBaseToolKit`, with the headers added.
#
# The policy session id is fixed per toolkit, which is right here: AgentCore gives each
# session its own container, and the container builds one agent. The token is not: an
# Identity token is fetched on every invocation, as the AgentCore SDK's
# `@requires_access_token` does, and outlives no invocation -- so a session longer than
# the token's lifetime keeps working.
#
# The token rides in the client's `auth`, not in per-request headers: `initialize` sends a
# `notifications/initialized` that takes no custom headers, and the Gateway answers it 401
# without a token. So a new token means a new client, connected with it.
isolated class GatewayToolKit {
    *ai:McpBaseToolKit;
    private final string serverUrl;
    private final map<string> & readonly headers;
    private mcp:StreamableHttpClient mcpClient;
    // The bearer token `mcpClient` was connected with. `()` when `config.auth` (client
    // credentials) supplies and renews the token itself.
    private string? token;
    private final ai:ToolConfig[] & readonly tools;

    # Connects to the Gateway and lists its (policy-filtered) tools.
    #
    # + serverUrl - The Gateway's MCP endpoint
    # + policySessionId - The policy session to attribute every request to
    # + token - A Gateway bearer token, or `()` when `config.auth` carries the credentials
    # + config - Transport configuration for the first connection; a reconnect for a new
    #            token carries only the token
    # + return - An error if the Gateway cannot be reached or refuses the request
    isolated function init(string serverUrl, string policySessionId, string? token,
            *mcp:StreamableHttpClientTransportConfig config) returns error? {
        self.serverUrl = serverUrl;
        self.headers = {[POLICY_SESSION_HEADER]: policySessionId}.cloneReadOnly();
        self.token = token;
        mcp:StreamableHttpClient mcpClient = check connect(serverUrl, self.headers, token, config);
        self.mcpClient = mcpClient;
        mcp:ListToolsResult listed = check mcpClient->listTools(self.headers);
        isolated function caller = self.callTool;
        self.tools = from mcp:ToolDefinition tool in listed.tools
            select {
                name: tool.name,
                description: tool.description ?: "",
                parameters: (<map<json>>tool.inputSchema).cloneReadOnly(),
                caller
            };
    }

    public isolated function getTools() returns ai:ToolConfig[] => self.tools;

    # Calls a Gateway tool with the current invocation's token, if it passed one.
    #
    # + ctx - The run's context; carries the invocation's Gateway token under `GATEWAY_TOKEN_KEY`
    # + params - The tool name and arguments
    # + return - The tool result, or an error
    @ai:AgentTool
    public isolated function callTool(ai:Context ctx, mcp:CallToolParams params)
            returns mcp:CallToolResult|error {
        string? token = ctx.hasKey(GATEWAY_TOKEN_KEY) ? check ctx.getWithType(GATEWAY_TOKEN_KEY) : ();
        mcp:StreamableHttpClient mcpClient = check self.clientFor(token);
        return mcpClient->callTool(params, self.headers);
    }

    # Returns a client connected with the given token, reconnecting only when it differs
    # from the current one -- AgentCore Identity may hand back the same token while it is
    # valid.
    #
    # + token - The invocation's Gateway token, or `()` to keep the current client
    # + return - The client to call the Gateway with, or an error if reconnecting fails
    isolated function clientFor(string? token) returns mcp:StreamableHttpClient|error {
        lock {
            if token is () || token == self.token {
                return self.mcpClient;
            }
            mcp:StreamableHttpClient mcpClient = check connect(self.serverUrl, self.headers, token, {});
            self.mcpClient = mcpClient;
            self.token = token;
            return mcpClient;
        }
    }
}

# Opens an MCP session with the Gateway.
#
# + serverUrl - The Gateway's MCP endpoint
# + headers - Headers sent on the `initialize` request
# + token - A Gateway bearer token, or `()` when `config.auth` carries the credentials
# + config - Transport configuration
# + return - An initialized client, or an error
isolated function connect(string serverUrl, map<string> & readonly headers, string? token,
        mcp:StreamableHttpClientTransportConfig config) returns mcp:StreamableHttpClient|error {
    if token is string {
        config.auth = {token};
    }
    mcp:StreamableHttpClient mcpClient = check new (serverUrl, config);
    check mcpClient->initialize({name: "ballerina-agent", version: "1.0.0"}, headers = headers);
    return mcpClient;
}

# Derives the Gateway policy session id from the AgentCore Runtime session id, so one
# conversation is one policy session. The Gateway accepts 1-128 characters of
# `[A-Za-z0-9-]`; a runtime id can be longer or carry other characters, so those are
# dropped and the rest truncated. Deterministic on purpose: a replacement container for
# the same runtime session continues the same policy session.
#
# + runtimeSessionId - The invocation's runtime session id
# + return - A valid policy session id
isolated function policySessionId(string runtimeSessionId) returns string {
    string id = re `[^A-Za-z0-9-]`.replaceAll(runtimeSessionId, "");
    if id == "" {
        return "default";
    }
    return id.length() > 128 ? id.substring(0, 128) : id;
}
