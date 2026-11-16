import ballerina/ai;
import ballerina/http;
import ballerina/log;

// AgentCore Runtime probes and invokes the container over HTTP on port 8080.
configurable int port = 8080;

// Open record: tolerate extra fields in the caller's payload.
type InvocationRequest record {
    string prompt;
};

type InvocationResponse record {|
    string response;
    string status;
|};

type FailureResponse record {|
    string message;
    string status;
|};

service / on new http:Listener(port) {

    // Health probe polled by AgentCore Runtime.
    resource function get ping() returns json => {status: "Healthy"};

    // Primary agent invocation endpoint.
    resource function post invocations(@http:Payload InvocationRequest payload,
            @http:Header {name: "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"} string? sessionId,
            http:Headers headers)
            returns http:Ok|http:InternalServerError {

        // AgentCore keeps one container session per session id, so it doubles
        // as the agent's memory key.
        string session = sessionId ?: "default";
        log:printInfo("invoking agent", session = session);

        // Which AgentCore Identity headers the Runtime delivered. Presence only: the
        // workload access token is a credential and its value must never be logged.
        log:printInfo("identity headers", session = session,
                workloadAccessToken = headers.hasHeader("WorkloadAccessToken"),
                identityWat = headers.hasHeader("X-Amz-Bedrock-AgentCore-Identity-WAT"),
                userId = headers.hasHeader("X-Amzn-Bedrock-AgentCore-Runtime-User-Id"),
                oauth2CallbackUrl = headers.hasHeader("OAuth2CallbackUrl"));

        // A fresh Gateway token for this invocation, as the AgentCore SDK's
        // `@requires_access_token` fetches one per invocation. `()` when Identity is not in use.
        string|http:HeaderNotFoundError workloadToken = headers.getHeader("WorkloadAccessToken");
        string?|error token = identityToken(workloadToken is string ? workloadToken : ());
        if token is error {
            log:printError("gateway token unavailable", token, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: token.message(), status: "error"}
            };
        }

        ai:Agent|error agent = agentFor(token, session);
        if agent is error {
            log:printError("agent unavailable", agent, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: agent.message(), status: "error"}
            };
        }

        // The toolkit sends this invocation's token on its tool calls.
        ai:Context context = new;
        if token is string {
            context.set(GATEWAY_TOKEN_KEY, token);
            log:printInfo("gateway token refreshed", tokenSource = "agentcore-identity", session = session);
        }

        string|ai:Error response = agent.run(payload.prompt, sessionId = session, context = context);
        if response is ai:Error {
            log:printError("agent run failed", response, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: response.message(), status: "error"}
            };
        }

        return <http:Ok>{body: <InvocationResponse>{response, status: "success"}};
    }
}
