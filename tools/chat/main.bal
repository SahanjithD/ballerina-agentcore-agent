import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerinax/aws.auth;

// Talk to the deployed agent over plain HTTPS -- no AWS CLI, no second language.
// `ballerinax/aws.auth` resolves credentials through the standard chain (env vars,
// AWS_PROFILE, ~/.aws, SSO, IMDS) and produces the SigV4 headers; `ballerina/http`
// sends the request.

configurable string region = "us-east-1";
configurable string runtimeArn = ?;

// Reuse one session id for the whole conversation: AgentCore pins a session to a
// container, and `service.bal` passes it to `ai:Agent.run` as the memory key. A new
// id per turn is what makes an agent forget you between messages.
configurable string sessionId = "";

const string SERVICE = "bedrock-agentcore";

public function main() returns error? {
    auth:CredentialProvider credentials = check new (auth:DEFAULT_CREDENTIALS);
    string host = string `${SERVICE}.${region}.amazonaws.com`;

    // The ARN is one path segment, so its colons and slash must be percent-encoded
    // on the wire. The SAME pre-encoded path is handed to the signer, together with
    // `s3PathMode` -- see the note on the signing call below.
    string signedPath = string `/runtimes/${encodeSegment(runtimeArn)}/invocations`;
    string wirePath = string `${signedPath}?qualifier=DEFAULT`;

    // AgentCore requires a session id of at least 33 characters.
    string session = sessionId == "" ? uuid:createType4AsString() + uuid:createType4AsString() : sessionId;

    http:Client agent = check new (string `https://${host}`);

    io:println(string `runtime ${runtimeArn}`);
    io:println(string `session ${session}`);
    io:println("Type your message. Blank line or \"exit\" to quit.\n");

    while true {
        string prompt = io:readln("you > ").trim();
        if prompt == "" || prompt == "exit" || prompt == "quit" {
            break;
        }

        byte[] payload = {"prompt": prompt}.toJsonString().toBytes();
        auth:Credentials creds = check credentials.getCredentials();
        map<string> signed = check auth:getSignedHeaders({
            method: "POST",
            host: host,
            path: signedPath,
            queryParams: {"qualifier": "DEFAULT"},
            headers: {
                "content-type": "application/json",
                "accept": "application/json",
                // Must be signed, not just sent: AgentCore rejects the request if this
                // header is absent from the signature.
                "x-amzn-bedrock-agentcore-runtime-session-id": session
            },
            payload: payload,
            // `s3PathMode` on a non-S3 service looks wrong, but it is required here.
            // SigV4 canonicalises the path by encoding the ALREADY-ENCODED URI again,
            // so the ARN's slash must end up as %252F. Left to itself this signer
            // encodes twice while treating "/" as a path separator, which yields a
            // literal "/" where AWS expects %252F, and every request 403s. Passing the
            // pre-encoded path with `s3PathMode` (encode once, do not normalise)
            // produces exactly the canonical URI AWS computes. Verified byte-for-byte
            // against botocore's SigV4Auth; do not "simplify" this.
            s3PathMode: true
        }, creds, region, SERVICE);

        http:Request request = new;
        request.setBinaryPayload(payload, "application/json");
        request.setHeader("accept", "application/json");
        request.setHeader("x-amzn-bedrock-agentcore-runtime-session-id", session);
        foreach [string, string] [name, value] in signed.entries() {
            request.setHeader(name, value);
        }

        http:Response|error response = agent->post(wirePath, request);
        if response is error {
            io:println(string `agent> request failed: ${response.message()}
`);
            continue;
        }
        io:println(string `agent> ${check render(response)}
`);
    }

    check credentials.close();
    io:println(string `
Session ${session} ended.`);
}

# Renders the runtime's reply, falling back to the raw body when it is not the
# `{"response": ..., "status": ...}` shape the agent normally returns.
#
# + response - The HTTP response from the runtime
# + return - Text to display, or an error if the body cannot be read
isolated function render(http:Response response) returns string|error {
    string body = check response.getTextPayload();
    if response.statusCode != 200 {
        return string `HTTP ${response.statusCode} ${body}`;
    }
    json parsed = check body.fromJsonString();
    if parsed is map<json> {
        json text = parsed["response"] ?: parsed["message"] ?: ();
        if text is string {
            return text;
        }
    }
    return body;
}

# Percent-encodes a value so it survives as a single path segment. The runtime ARN
# contains `:` and `/`, both of which must become %3A/%2F or the URL addresses the
# wrong resource.
#
# + value - The raw value, e.g. a runtime ARN
# + return - The encoded segment
isolated function encodeSegment(string value) returns string {
    string out = "";
    foreach string:Char c in value {
        if isUnreserved(c) {
            out += c;
            continue;
        }
        foreach byte b in c.toBytes() {
            out += "%" + b.toHexString().toUpperAscii().padZero(2);
        }
    }
    return out;
}

# RFC 3986 unreserved characters, which must be left alone when encoding.
#
# + c - The character to test
# + return - Whether the character may appear unencoded
isolated function isUnreserved(string:Char c) returns boolean =>
    (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
        || c == "-" || c == "." || c == "_" || c == "~";
