import ballerina/log;

// The AgentCore Runtime contract is served by the HTTP service in `service.bal`.
// `main` only records startup; it must not block or the listener never starts.
public function main() {
    log:printInfo("ballerina agent starting", port = port);
}
