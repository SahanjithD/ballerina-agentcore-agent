import ballerina/http;
import ballerina/time;
import ballerina/uuid;

// The Lambda Web Adapter forwards the Function URL request to a normal HTTP server on
// this port (its `AWS_LWA_PORT` default), so the service needs no Lambda-specific code.
configurable int port = 8080;

# A greeting rendered by this service.
#
# + message - The greeting text
# + servedBy - Which backend produced the greeting
# + utcTime - Time the greeting was produced, in UTC
type Greeting record {|
    string message;
    string servedBy;
    string utcTime;
|};

# A batch of freshly generated identifiers.
#
# + uuids - The generated UUIDs
# + count - How many were generated
type UuidBatch record {|
    string[] uuids;
    int count;
|};

# A rejected request.
#
# + message - Why the request was rejected
type ErrorMessage record {|
    string message;
|};

service /v1 on new http:Listener(port) {

    // The adapter polls this before it will forward traffic; it is pointed here with
    // AWS_LWA_READINESS_CHECK_PATH so a cold JVM is never handed a real request.
    resource function get health() returns json => {status: "ok"};

    resource function get greet/[string name]() returns Greeting => {
        message: string `Hello, ${name}!`,
        servedBy: "Ballerina REST API on AWS Lambda",
        utcTime: time:utcToString(time:utcNow())
    };

    resource function get uuid(int count = 1) returns UuidBatch|http:BadRequest {
        // Bounded deliberately: `count` reaches this straight from a model-generated
        // tool call, so an unbounded value is an easy way to burn the Lambda timeout.
        if count < 1 || count > 20 {
            return <http:BadRequest>{
                body: <ErrorMessage>{message: "count must be between 1 and 20"}
            };
        }
        string[] uuids = [];
        foreach int _ in 0 ..< count {
            uuids.push(uuid:createRandomUuid());
        }
        return {uuids, count};
    }
}
