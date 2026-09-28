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
            @http:Header {name: "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"} string? sessionId)
            returns http:Ok|http:InternalServerError {

        // AgentCore keeps one container session per session id, so it doubles
        // as the agent's memory key.
        string session = sessionId ?: "default";
        log:printInfo("invoking agent", session = session);

        string|ai:Error response = assistantAgent.run(payload.prompt, sessionId = session);
        if response is ai:Error {
            log:printError("agent run failed", response, session = session);
            return <http:InternalServerError>{
                body: <FailureResponse>{message: response.message(), status: "error"}
            };
        }

        return <http:Ok>{body: <InvocationResponse>{response, status: "success"}};
    }
}
