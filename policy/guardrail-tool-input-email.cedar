// Block a tool call whose argument contains an email address, before the tool runs.
//
// Guardrail policies use AWS's extended policy language. Via the API pass the statement
// under {"policy": {"statement": ...}} -- with {"cedar": ...} the parse fails with
// "unexpected token `guardrails`". A "when guardrails" block cannot be mixed with a plain
// "when" condition. The argument must be a string-typed field.
//
// Proven (ACTIVE): greetPerson(name="jane.doe@example.com") returned
// "Tool Execution Denied: ... [Policy evaluation denied due to guardrail_greet_email_input-...]"
// and the Lambda behind the tool was never invoked.
forbid (
    principal,
    action == AgentCore::Action::"ballerinaRestApi___greetPerson",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["EMAIL"], [context.input.name]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
