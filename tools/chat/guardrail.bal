import ballerina/http;
import ballerinax/aws.auth;

// Bedrock Guardrails applied as a standalone check.
//
// `ApplyGuardrail` evaluates arbitrary text against a guardrail WITHOUT invoking a
// model, and that is the whole reason it is usable here. This agent reaches Claude
// through `ballerinax/ai.anthropic`, i.e. api.anthropic.com directly, so there is no
// Bedrock model invocation for a guardrail to ride along with. AgentCore Policy does
// not cover this either -- a policy engine attaches to a Gateway, so it only ever sees
// MCP traffic, never the chat turn. Calling the API explicitly is what closes the gap.

// SigV4 signing name for both the `bedrock` and `bedrock-runtime` endpoints.
const string BEDROCK_SERVICE = "bedrock";

# The outcome of an `ApplyGuardrail` call.
#
# + intervened - Whether the guardrail blocked or masked the text
# + text - The guardrail's replacement text when it intervened, otherwise the original
# + reason - Why the guardrail intervened, when it reports one
public type GuardrailVerdict record {|
    boolean intervened;
    string text;
    string reason = "";
|};

# Evaluates one piece of text against a Bedrock guardrail.
#
# + bedrock - Client pointed at the `bedrock-runtime` endpoint
# + credentials - Resolved AWS credential provider
# + host - The host the client points at; needed separately because it is signed
# + region - Region the guardrail lives in
# + id - Guardrail identifier
# + version - Guardrail version number, or `DRAFT`
# + text - The text to evaluate
# + source - `INPUT` for text on its way to the model, `OUTPUT` for text coming back
# + return - The guardrail's verdict, or an error if the call itself failed
isolated function applyGuardrail(http:Client bedrock, auth:CredentialProvider credentials,
        string host, string region, string id, string version, string text, string 'source)
        returns GuardrailVerdict|error {

    // A guardrail id and version contain only unreserved characters, so the default
    // (non-S3) signing mode canonicalises this path correctly. Contrast `main.bal`,
    // where the runtime ARN's `:` and `/` force the pre-encoded path plus `s3PathMode`.
    string path = string `/guardrail/${id}/version/${version}/apply`;
    byte[] payload = {
        "source": 'source,
        "content": [{"text": {"text": text}}]
    }.toJsonString().toBytes();

    auth:Credentials creds = check credentials.getCredentials();
    map<string> signed = check auth:getSignedHeaders({
        method: "POST",
        host: host,
        path: path,
        headers: {"content-type": "application/json"},
        payload: payload
    }, creds, region, BEDROCK_SERVICE);

    http:Request request = new;
    request.setBinaryPayload(payload, "application/json");
    foreach [string, string] [name, value] in signed.entries() {
        request.setHeader(name, value);
    }

    http:Response response = check bedrock->post(path, request);
    string body = check response.getTextPayload();
    if response.statusCode != 200 {
        return error(string `ApplyGuardrail returned HTTP ${response.statusCode}: ${body}`);
    }

    json parsed = check body.fromJsonString();
    // `action` is GUARDRAIL_INTERVENED when a policy matched, NONE when nothing did.
    json|error action = parsed.action;
    if action !is string || action != "GUARDRAIL_INTERVENED" {
        return {intervened: false, text: text};
    }

    json|error reason = parsed.actionReason;
    return {
        intervened: true,
        // `outputs` carries the guardrail's own blocked message, or the text with
        // matches masked. It can be absent, so keep the original as a fallback.
        text: firstOutput(parsed) ?: text,
        reason: reason is string ? reason : ""
    };
}

# Pulls the guardrail's replacement text out of an `ApplyGuardrail` response.
#
# + parsed - The parsed response body
# + return - The first output text, or `()` if the response carried none
isolated function firstOutput(json parsed) returns string? {
    json|error outputs = parsed.outputs;
    if outputs !is json[] || outputs.length() == 0 {
        return ();
    }
    json|error text = outputs[0].text;
    return text is string ? text : ();
}
