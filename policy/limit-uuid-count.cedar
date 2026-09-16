// Cap generateUuids at 5 per call, at the gateway boundary.
//
// tools/rest-api/service.bal already rejects count > 20, but that check lives inside
// the tool. This one lives outside the agent entirely: it holds even if the agent is
// prompt-injected, the model misbehaves, or the Ballerina service is redeployed with
// a laxer limit. That is the whole point of Policy -- enforcement the agent cannot talk
// its way around.
//
// `forbid` wins over `permit`, so this overrides the baseline above.
//
// Action naming is "<targetName>___<toolName>" -- three underscores. Confirm yours with
// tools/list against the gateway before relying on it.
forbid(
    principal,
    action == AgentCore::Action::"ballerina-rest-api___generateUuids",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
)
when {
    context.input.count > 5
};
