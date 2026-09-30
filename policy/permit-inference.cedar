// Permit model calls through a Gateway inference target.
//
// The action is <target-name>___<METHOD>:<path> with NO /inference prefix, and it uses the
// target's name even if the target's connector changed (this target is named "anthropic"
// but uses the OpenAI connector). The Responses API is a separate action:
// <target>___POST:/v1/responses.
// API definition key: {"cedar": ...}; create with --validation-mode IGNORE_ALL_FINDINGS.
//
// Proven: the agent answered normally with the Gateway in ENFORCE.
permit (
    principal,
    action == AgentCore::Action::"anthropic___POST:/v1/chat/completions",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
