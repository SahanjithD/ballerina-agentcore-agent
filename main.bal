import ballerina/log;

// Imported for its side effect only: this registers the `otel` tracing provider that
// `Config.toml` selects. Nothing in this package calls it, and without the import
// Ballerina never resolves the package, so the provider is missing at runtime.
import ballerina/otel as _;

// The AgentCore Runtime contract is served by the HTTP service in `service.bal`.
// `main` only records startup; it must not block or the listener never starts.
public function main() {
    log:printInfo("ballerina agent starting", port = port);
}
