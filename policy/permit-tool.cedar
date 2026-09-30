// Permit one Gateway tool. Tool actions are named <target>___<tool>.
//
// Validation reports "Overly Permissive" for an action-scoped permit that allows any
// principal; create it with --validation-mode IGNORE_ALL_FINDINGS when that is intended.
// API definition key: {"cedar": {"statement": ...}}
//
// Proven: with only this permit active (plus inference), enforce-mode tools/list returned
// exactly this one tool out of 8, and calling an unpermitted tool returned
// "Tool call not allowed due to policy enforcement [No policy applies to the request (denied by default).]"
permit (
    principal,
    action == AgentCore::Action::"ballerinaMcpServer___whoAmI",
    resource == AgentCore::Gateway::"GATEWAY_ARN_PLACEHOLDER"
);
