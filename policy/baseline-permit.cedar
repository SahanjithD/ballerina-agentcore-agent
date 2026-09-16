// Baseline: permit every tool on this gateway.
//
// This exists because ENFORCE mode is DEFAULT-DENY. Attaching a policy engine in
// ENFORCE without a baseline permit silently breaks every existing target --
// deepwiki and weather included -- not just the ones you meant to restrict.
//
// Cedar rejects wildcard resources, so the gateway ARN must be written out in full.
permit(
    principal,
    action,
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
