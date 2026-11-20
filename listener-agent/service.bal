import ballerina/ai;
import ballerina/http;
import ballerinax/ai.aws.bedrock.agentcore;

// Imported for its side effect only: this registers the `otel` tracing provider that
// the baked-in `Config.toml` selects.
import ballerina/otel as _;

// The service WSO2 Agent Builder generates for the AgentCore trigger, unchanged except
// for the lines marked `Identity`. Those are what the Identity path adds on top of the
// listener: the listener hands over the workload access token in `ctx`, and the rest
// (the token exchange, the per-invocation agent, passing the token to the toolkit) is
// code you write.
listener agentcore:Listener agentcoreListener = new ();

service agentcore:InvocationService on agentcoreListener {
    resource function get ping() returns agentcore:PingStatus => agentcore:HEALTHY;

    resource function post invocations(@http:Payload json payload, agentcore:Context ctx)
            returns json|error {
        string message = check payload.prompt;
        string sessionId = ctx.sessionId ?: ctx.requestId;

        // Identity: trade the workload access token in `ctx` for a Gateway token.
        string token = check gatewayToken(ctx);
        // Identity: the agent is built on the first invocation instead of at module level,
        // because the Gateway toolkit lists its tools with a token.
        ai:Agent aiAgent = check agentFor(token, sessionId);
        // Identity: the toolkit sends this invocation's token on its tool calls.
        ai:Context context = new;
        context.set(GATEWAY_TOKEN_KEY, token);

        // Identity: `context = context` is added to the generated call.
        string reply = check aiAgent.run(message, sessionId = sessionId, context = context);
        return {response: reply, sessionId};
    }
}
