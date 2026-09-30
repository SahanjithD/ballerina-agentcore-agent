// Prompt-injection check on a tool argument. Deployed in LOG_ONLY.
// API definition key: {"policy": ...}. A forbid on a tool nothing permits yet reports
// "Overly Restrictive"; create with --validation-mode IGNORE_ALL_FINDINGS.
// Status: saves and is ACTIVE; blocking has not been exercised.
forbid (
    principal,
    action == AgentCore::Action::"ballerinaMcpServer___countWords",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::PromptAttack(["PROMPT_INJECTION"], [context.input.text])["PROMPT_INJECTION"]
        .confidenceScore
        .greaterThan(decimal("0.0"))
};
