import ballerina/ai;
import ballerina/http;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;
configurable anthropic:ANTHROPIC_MODEL_NAMES modelType = anthropic:CLAUDE_OPUS_4_6;

// An AgentCore Gateway -- or any MCP server -- speaking streamable HTTP. Its tools are
// discovered at startup and offered to the agent alongside the local ones below.
// Leave empty to run with local tools only.
configurable string mcpServerUrl = "";
configurable string mcpAuthToken = "";

@ai:AgentTool
isolated function sum(int a, int b) returns int => a + b;

@ai:AgentTool
isolated function multiply(int a, int b) returns int => a * b;

final ai:ModelProvider claudeModel = check new anthropic:ModelProvider(anthropicApiKey, modelType);

final http:BearerTokenConfig? gatewayAuth = mcpAuthToken == "" ? () : {token: mcpAuthToken};

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
