import ballerina/ai;
import ballerina/time;
import ballerinax/ai.aws.bedrock;
import ballerinax/ai.aws.dynamodb as memorydb;
import ballerinax/aws.auth;
import ballerinax/aws.secretmanager;

// The model is called on Amazon Bedrock directly, signed with the runtime's execution role.
// No token to expire and no provider key anywhere, but model calls do not pass through
// the Gateway, so Cedar policy does not see them. The guardrail below is applied by Bedrock
// itself on every call instead.
configurable string bedrockModel = bedrock:NOVA_LITE;

// A Bedrock guardrail applied to every model call. Leave the id empty to call without one.
configurable string guardrailId = "";
configurable string guardrailVersion = "";

// The AgentCore Gateway's MCP endpoint. Its tools are discovered when the agent is built
// and offered alongside the local ones below.
configurable string mcpServerUrl = "https://ballerina-agent-gatewa-01gzl3luj1.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp";

// Conversation memory in DynamoDB, so a session survives its container being replaced.
// The secret holds the memory table's access key: {"accessKeyId": "...", "secretAccessKey": "..."}.
// `ai.aws.dynamodb` cannot use the execution role yet, hence a key of its own, scoped to the table.
// Leave the secret id empty to keep memory inside the container.
configurable string memorySecretId = "";
configurable string memoryTable = "ballerina_agent_memory";

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
# Gateway.
#
# + return - Identity of the agent process
@ai:AgentTool
isolated function whereAmIRunning() returns AgentIdentity => {
    servedBy: "ballerina-agent-listener, in-process @ai:AgentTool",
    language: "Ballerina 2201.14.0 (Swan Lake Update 14), agentcore:Listener",
    utcTime: time:utcToString(time:utcNow())
};

# Builds the DynamoDB-backed memory store. The access key is read from Secrets Manager with
# the runtime's IAM role, so it never appears in the runtime configuration.
#
# + return - The memory store, or an error if the secret or the table cannot be reached
isolated function memoryStore() returns ai:ShortTermMemoryStore|error {
    secretmanager:Client secrets = check new ({region: awsRegion, auth: auth:DEFAULT_CREDENTIALS});
    secretmanager:SecretValue secret = check secrets->getSecretValue(memorySecretId);
    byte[]|string value = secret.value;
    string secretString = value is string ? value : check string:fromBytes(value);
    json keys = check secretString.fromJsonString();
    return new memorydb:ShortTermMemoryStore({
        region: awsRegion,
        awsCredentials: {
            accessKeyId: (check keys.accessKeyId).toString(),
            secretAccessKey: (check keys.secretAccessKey).toString()
        }
    }, tableConfig = {tableName: memoryTable});
}

# Builds the agent.
#
# Built on the first invocation rather than at startup, because the workload access token,
# and so the Gateway token, only exists per request. AgentCore gives each session its own
# container, so one agent per container is one agent per session.
#
# + token - This invocation's Gateway token from AgentCore Identity
# + sessionId - The runtime session id, which becomes the Gateway policy session id
# + return - The agent, or an error if the Gateway, the model or the memory cannot be reached
isolated function buildAgent(string token, string sessionId) returns ai:Agent|error {
    // The toolkit lists tools in its `init`, so the Gateway's (policy-filtered) tool list
    // is fixed when the agent is built. The token is replaced on every invocation (see
    // `service.bal`).
    GatewayToolKit gateway = check new (mcpServerUrl, policySessionId(sessionId), token);

    ai:ModelProvider model;
    if guardrailId != "" {
        model = check new bedrock:RuntimeAmazonModelProvider(bedrockModel, auth:DEFAULT_CREDENTIALS,
            awsRegion, guardrail = {guardrailIdentifier: guardrailId, guardrailVersion});
    } else {
        model = check new bedrock:RuntimeAmazonModelProvider(bedrockModel, auth:DEFAULT_CREDENTIALS, awsRegion);
    }

    ai:Memory memory = memorySecretId == ""
        ? check new ai:ShortTermMemory()
        : check new ai:ShortTermMemory(check memoryStore());

    // A plain literal for `tools`, so the Ballerina visual editor can display every tool.
    return check new ai:Agent(
        systemPrompt = {
            role: "Assistant",
            instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
        }, memory = memory, model = model, tools = [sum, multiply, whereAmIRunning, gateway]
    );
}

isolated ai:Agent? cachedAgent = ();

# Returns this container's agent, building it on first use.
#
# + token - This invocation's Gateway token from AgentCore Identity
# + sessionId - The invocation's runtime session id
# + return - The agent, or an error
isolated function agentFor(string token, string sessionId) returns ai:Agent|error {
    lock {
        ai:Agent? existing = cachedAgent;
        if existing is ai:Agent {
            return existing;
        }
    }
    ai:Agent agent = check buildAgent(token, sessionId);
    lock {
        cachedAgent = agent;
    }
    return agent;
}
