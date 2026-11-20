import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerinax/ai.aws.bedrock.agentcore;

// Imported for its side effect only: this registers the `otel` tracing provider that
// the baked-in `Config.toml` selects. Without the import Ballerina never resolves the
// package, so the provider is missing at runtime.
import ballerina/otel as _;

// Open record: tolerate extra fields in the caller's payload. The listener binds the
// body strictly, so a closed record would reject them.
type InvocationRequest record {
    string prompt;
};

type InvocationResponse record {|
    string response;
    string status;
|};

// Port 8080, a 900 second timeout and 96 KB of headers: the AgentCore Runtime contract
// and limits, all defaults of the listener.
listener agentcore:Listener agentCoreListener = new;

service on agentCoreListener {

    // Health probe polled by AgentCore Runtime. The listener adds `time_of_last_update`.
    resource function get ping() returns agentcore:PingStatus => agentcore:HEALTHY;

    // Primary agent invocation endpoint. An error goes back as a 500 with a generic body
    // (AgentCore shows the caller a 424); the listener logs its cause with the request
    // and session ids, so the reason is in CloudWatch, not in the response.
    resource function post invocations(@http:Payload InvocationRequest payload, agentcore:Context ctx)
            returns InvocationResponse|error {

        // AgentCore keeps one container session per session id, so it doubles as the
        // agent's memory key.
        string session = ctx.sessionId ?: "default";
        log:printInfo("invoking agent", session = session, requestId = ctx.requestId);

        // Which AgentCore Identity values the listener found. Presence only: the workload
        // access token is a credential and its value must never be logged.
        log:printInfo("identity context", session = session,
                workloadAccessToken = ctx.workloadAccessToken is string,
                oauth2CallbackUrl = ctx.oauth2CallbackUrl is string,
                authorization = ctx.authorization is string);

        // The Identity path is the only path here: no workload access token, no Gateway
        // token. The Runtime sends one only when the caller names a user
        // (`--runtime-user-id`, needs InvokeAgentRuntimeForUser) or with JWT inbound auth.
        string? workloadToken = ctx.workloadAccessToken;
        if workloadToken is () {
            return error("no workload access token: invoke with a runtime user id, or put a " +
                    "JWT authorizer on the runtime");
        }

        // A fresh Gateway token for this invocation, as the AgentCore SDK's
        // `@requires_access_token` fetches one per invocation.
        string token = check gatewayTokenFromIdentity(workloadToken);
        log:printInfo("gateway token obtained", tokenSource = "agentcore-identity", session = session);

        ai:Agent agent = check agentFor(token, session);

        // The toolkit sends this invocation's token on its tool calls.
        ai:Context context = new;
        context.set(GATEWAY_TOKEN_KEY, token);

        string response = check agent.run(payload.prompt, sessionId = session, context = context);
        return {response, status: "success"};
    }
}
