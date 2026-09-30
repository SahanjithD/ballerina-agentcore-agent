// Screen a model call through the inference target with a Bedrock guardrail.
//
// Only plain-string fields of the request body can be screened. OpenAI Chat Completions
// carries the prompt in "messages", which Cedar types Set<record>, and a guardrail rejects it:
//   "argument `context.input.messages` has type `Set<record>` ... but the provider
//    declares argument type `string`"
// The Responses API's "instructions" is a string, so it works; its "input" is typed
// record (string-or-list) and its string member could not be addressed.
// API definition key: {"policy": ...}.
//
// Proven (ACTIVE): an email in "instructions" returned
// "Request Denied: ... [Policy evaluation denied due to guardrail_inference_instructions-...]"
// (403); the same request without it returned 200.
forbid (
    principal,
    action == AgentCore::Action::"anthropic___POST:/v1/responses",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["EMAIL"], [context.input.instructions]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
