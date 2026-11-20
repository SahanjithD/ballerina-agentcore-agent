import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/uuid;
import ballerinax/ai.aws.bedrock.agentcore;

// Imported for its side effect only: this registers the `otel` tracing provider that
// the baked-in `Config.toml` selects. Without the import Ballerina never resolves the
// package, so the provider is missing at runtime.
import ballerina/otel as _;

// Port 8080, a 900 second timeout and 96 KB of headers: the AgentCore Runtime contract
// and limits, all defaults of the listener.
listener agentcore:Listener agentCoreListener = new;

// The shape WSO2 Agent Builder generates for the AgentCore trigger, with the Identity
// steps added. Two changes from the generated code:
// - `@http:Payload` on `payload`: the listener's compiler plugin rejects an unannotated
//   parameter, so the generated resource does not compile as is.
// - A fresh UUID, not `ctx.requestId`, when there is no session id: the request id is
//   caller-controlled, and the module says never to use it as an isolation key.
service on agentCoreListener {

    // Health probe polled by AgentCore Runtime. The listener adds `time_of_last_update`.
    resource function get ping() returns agentcore:PingStatus => agentcore:HEALTHY;

    // An error goes back as a 500 with a generic body (AgentCore shows the caller a 424);
    // the listener logs its cause with the request and session ids, so the reason is in
    // CloudWatch, not in the response.
    resource function post invocations(@http:Payload json payload, agentcore:Context ctx) returns json|error {
        string message = check payload.prompt;
        string sessionId = ctx.sessionId ?: uuid:createType4AsString();
        log:printInfo("invoking agent", session = sessionId, requestId = ctx.requestId);

        // Presence only: the workload access token is a credential and its value must
        // never be logged.
        log:printInfo("identity context", session = sessionId,
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
        log:printInfo("gateway token obtained", tokenSource = "agentcore-identity", session = sessionId);

        // Not a module-level `aiAgent` as generated: the Gateway toolkit lists its tools
        // with a token, and the token only exists per invocation.
        ai:Agent aiAgent = check agentFor(token, sessionId);

        // The toolkit sends this invocation's token on its tool calls.
        ai:Context context = new;
        context.set(GATEWAY_TOKEN_KEY, token);

        string reply = check aiAgent.run(message, sessionId = sessionId, context = context);
        return {response: reply, sessionId};
    }
}
