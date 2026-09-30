// Let the tool run, but withhold its response from the agent when the response contains
// a person's name. suppressOutput conditions may only contain guardrail checks.
// API definition key: {"policy": ...}.
//
// Proven (ACTIVE): greetPerson(name="Jane Smith") -- the Lambda ran (logged invocation),
// and the caller received
// "Output blocked by policy: Policy evaluation denied due to guardrail_greet_name_output-...".
suppressOutput (
    principal,
    action == AgentCore::Action::"ballerinaRestApi___greetPerson",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when guardrails {
    BedrockGuardrails::SensitiveInformation(["NAME"], [context.output.message]).maxConfidenceScore().greaterThan(decimal("0.0"))
};
