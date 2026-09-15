import ballerina/mcp;
import ballerina/time;

// AgentCore Runtime's MCP protocol contract fixes both the port and the path: the
// container must speak streamable HTTP on `0.0.0.0:8000/mcp`. Neither is negotiable
// -- a server on 8080, or mounted anywhere but /mcp, is simply never reached.
configurable int port = 8000;

listener mcp:StreamableHttpListener mcpListener = new (port);

# Proof of which server answered a tool call.
#
# + server - Name this server reports over MCP
# + language - Language and distribution the server is built on
# + hostedOn - Platform the server is running on
# + utcTime - Time the call was handled, in UTC
type ServerIdentity record {|
    string server;
    string language;
    string hostedOn;
    string utcTime;
|};

@mcp:StreamableHttpServiceConfig {
    info: {
        name: "Ballerina Tools",
        version: "0.1.0"
    },
    // STATELESS because the Gateway is the only client and it does not carry a session
    // across calls: it syncs the tool list once at target creation, then invokes tools
    // independently. Stateful mode would have AgentCore pin an `Mcp-Session-Id` per
    // container for no benefit here.
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Count the whitespace-separated words in a piece of text.
    #
    # + text - The text whose words should be counted
    # + return - The number of words found
    remote function countWords(string text) returns int {
        int count = 0;
        foreach string token in re `\s+`.split(text.trim()) {
            if token != "" {
                count += 1;
            }
        }
        return count;
    }

    # Identify the server that is handling this tool call. Use this to confirm which
    # backend a tool actually reached.
    #
    # + return - The server's name, language and hosting platform
    remote function whoAmI() returns ServerIdentity => {
        server: "Ballerina Tools",
        language: "Ballerina 2201.13.5 (Swan Lake Update 13)",
        hostedOn: "Amazon Bedrock AgentCore Runtime",
        utcTime: time:utcToString(time:utcNow())
    };
}
