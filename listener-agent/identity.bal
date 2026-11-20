// Obtains the agent's Gateway token from AgentCore Identity instead of from a client
// secret held in the container.
//
// This is what the Python SDK's `@requires_access_token(auth_flow="M2M")` does, written as
// the one HTTP call it makes. The listener reads the workload access token the Runtime
// hands over on each invocation into `agentcore:Context`; the agent trades it, with its
// execution role's SigV4 signature, for an OAuth token from a credential provider whose
// client secret lives in the Identity token vault.
import ballerina/http;
import ballerinax/aws;
import ballerinax/aws.auth;

// Name of the OAuth2 credential provider in AgentCore Identity that holds the Gateway's
// Cognito client. Required: this agent has no other way to reach the Gateway.
configurable string gatewayCredentialProvider = ?;
configurable string awsRegion = "us-east-1";

// The data-plane endpoint (`bedrock-agentcore.<region>.amazonaws.com`); SigV4 signing name
// is `bedrock-agentcore`.
final string identityHost = aws:resolveEndpointHost("bedrock-agentcore", awsRegion);
final http:Client identityClient = check new (aws:resolveEndpoint("bedrock-agentcore", awsRegion));

// The default credential chain resolves the runtime's execution role inside AgentCore.
final auth:CredentialProvider awsCredentials = check new (auth:DEFAULT_CREDENTIALS);

# Exchanges the Runtime's workload access token for a Gateway token (M2M flow).
#
# + workloadToken - `agentcore:Context.workloadAccessToken` of the current invocation
# + return - An access token for the Gateway, or an error
isolated function gatewayTokenFromIdentity(string workloadToken) returns string|error {
    string path = "/identities/oauth2/token";
    // No scopes: Cognito then grants every scope the client is allowed.
    json requestBody = {
        resourceCredentialProviderName: gatewayCredentialProvider,
        scopes: [],
        oauth2Flow: "M2M",
        workloadIdentityToken: workloadToken
    };
    byte[] payload = requestBody.toJsonString().toBytes();
    map<string> signedHeaders = check auth:getSignedHeaders({
        method: "POST",
        host: identityHost,
        path,
        headers: {"content-type": "application/json"},
        payload
    }, check awsCredentials.getCredentials(), awsRegion, "bedrock-agentcore");
    // Open record: the response also carries sessionUri/sessionStatus for user flows.
    record {string accessToken?;} response =
            check identityClient->post(path, payload, signedHeaders, "application/json");
    string? accessToken = response.accessToken;
    if accessToken is () {
        return error("AgentCore Identity returned no access token for " + gatewayCredentialProvider);
    }
    return accessToken;
}
