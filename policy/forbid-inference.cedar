// Deny every model call through the inference target. Test policy: it shows Cedar governs
// the model conversation, not just tools.
// API definition key: {"cedar": ...}; create with --validation-mode IGNORE_ALL_FINDINGS.
//
// Proven: the agent's model call failed with
// "Request Denied: Gateway Target request not allowed due to policy enforcement
//  [Policy evaluation denied due to test_forbid_inference-...]" (403, permission_error).
forbid (
    principal,
    action == AgentCore::Action::"anthropic___POST:/v1/chat/completions",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
