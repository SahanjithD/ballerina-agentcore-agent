import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/ai.aws.bedrock;
import ballerinax/ai.aws.dynamodb as memorydb;
import ballerinax/aws.auth;
import ballerinax/aws.secretmanager;

// The model is called on Amazon Bedrock directly, signed with the runtime's execution role.
// No token to expire and no provider key anywhere -- but model calls no longer pass through
// the Gateway, so Cedar policy does not see them. The guardrail below is applied by Bedrock
// itself on every call instead.
configurable string bedrockModel = bedrock:NOVA_LITE;

// A Bedrock guardrail applied to every model call. Leave the id empty to call without one.
configurable string guardrailId = "";
configurable string guardrailVersion = "";

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
# Gateway. Asking both in one conversation is the cheapest way to see the difference --
# in the trace the local call is a bare `execute_tool` span with no HTTP beneath it,
# while the Gateway one carries a whole client stack and the Gateway's own spans.
#
# + return - Identity of the agent process
@ai:AgentTool
isolated function whereAmIRunning() returns AgentIdentity => {
    servedBy: "ballerina-agent, in-process @ai:AgentTool",
    language: "Ballerina 2201.14.1 (Swan Lake Update 14)",
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

# Gets this invocation's Gateway token from AgentCore Identity, when it is configured and
# the Runtime passed a workload access token. Called on every invocation, as the AgentCore
# SDK's `@requires_access_token` is: the workload token arrives fresh with each one, so the
# Gateway token is never older than the invocation using it.
#
# + workloadToken - The invocation's `WorkloadAccessToken` header, if any
# + return - A Gateway bearer token, `()` if Identity is not in use, or an error
isolated function identityToken(string? workloadToken) returns string?|error {
    if gatewayCredentialProvider != "" && workloadToken is string {
        return gatewayTokenFromIdentity(workloadToken);
    }
    return ();
}

# Picks the Gateway token the agent is built with. This invocation's AgentCore Identity
# token if there is one; otherwise a static token, then the client secret -- the fallbacks
# exist so the agent still runs when invoked without a user id.
#
# + invocationToken - This invocation's token from AgentCore Identity, if any
# + return - A Gateway bearer token and where it came from, or an error
isolated function gatewayToken(string? invocationToken) returns [string, string]|error {
    if invocationToken is string {
        return [invocationToken, "agentcore-identity"];
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
# Built on the first invocation rather than at startup, because the workload access token
# only exists per request. AgentCore gives each session its own container, so one agent per
# container is one agent per session.
#
# + token - A Gateway bearer token, or `()` to use the client credentials
# + sessionId - The runtime session id, which becomes the Gateway policy session id
# + return - The agent, or an error if the Gateway, the model or the memory cannot be reached
isolated function buildAgent(string? token, string sessionId) returns ai:Agent|error {
    // The toolkit lists tools in its `init`, so the Gateway's (policy-filtered) tool list
    // is fixed when the agent is built. With client credentials the toolkit renews its own
    // token. An Identity token is replaced on every invocation (see `service.bal`); a
    // static token stops working when it expires.
    GatewayToolKit gateway;
    if token is () {
        gateway = check new (mcpServerUrl, policySessionId(sessionId), (),
            auth = {tokenUrl: mcpTokenUrl, clientId: mcpClientId, clientSecret: mcpClientSecret});
    } else {
        gateway = check new (mcpServerUrl, policySessionId(sessionId), token);
    }

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
# + invocationToken - This invocation's token from AgentCore Identity, if any
# + sessionId - The invocation's runtime session id
# + return - The agent, or an error
isolated function agentFor(string? invocationToken, string sessionId) returns ai:Agent|error {
    lock {
        ai:Agent? existing = cachedAgent;
        if existing is ai:Agent {
            return existing;
        }
    }
    [string, string] [token, tokenSource] = check gatewayToken(invocationToken);
    log:printInfo("gateway token obtained", tokenSource = tokenSource);
    ai:Agent agent = check buildAgent(tokenSource == "client-secret" ? () : token, sessionId);
    lock {
        cachedAgent = agent;
    }
    return agent;
}
