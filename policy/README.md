# AgentCore Policy examples

Every file here was deployed to a live AgentCore Gateway and behaved as its header comment
says. Replace `GATEWAY_ARN_PLACEHOLDER` with your Gateway's ARN and the target names with
your own (`<target>___<tool>`; target names must be camelCase, see
[BALLERINA-ON-AGENTCORE.md §2.1](../BALLERINA-ON-AGENTCORE.md)).

| File | Effect | Definition key | Validation mode | Proven result |
|---|---|---|---|---|
| `baseline-permit.cedar` | Allow every tool on the Gateway | `cedar` | default | Keeps existing tools working when switching to ENFORCE |
| `permit-tool.cedar` | Allow one tool | `cedar` | `IGNORE_ALL_FINDINGS` | `tools/list` returned only that tool (1 of 8) |
| `limit-uuid-count.cedar` | Deny a tool call by argument value | `cedar` | `IGNORE_ALL_FINDINGS` | Calls with `count > 5` denied (proven under the pre-rename target name; recreated, not re-run) |
| `permit-inference.cedar` | Allow model calls through the inference target | `cedar` | `IGNORE_ALL_FINDINGS` | Agent answered with the Gateway in ENFORCE |
| `forbid-inference.cedar` | Deny model calls | `cedar` | `IGNORE_ALL_FINDINGS` | Agent's model call got 403 naming the policy |
| `guardrail-tool-input-email.cedar` | Block a tool call whose input has an email | `policy` | `IGNORE_ALL_FINDINGS` | Denied; the tool was never invoked |
| `guardrail-tool-output-name.cedar` | Withhold a tool's response that contains a name (`suppressOutput`) | `policy` | `IGNORE_ALL_FINDINGS` | Tool ran; caller got `Output blocked by policy` |
| `guardrail-inference-instructions.cedar` | Block a model call whose `instructions` has an email | `policy` | `IGNORE_ALL_FINDINGS` | 403 with the email, 200 without |
| `guardrail-prompt-attack.cedar` | Prompt-injection check on a tool input | `policy` | `IGNORE_ALL_FINDINGS` | Saves; deployed LOG_ONLY, blocking not exercised |

## Deploying one

Plain Cedar goes under `cedar`; anything with `when guardrails` or `suppressOutput` goes
under `policy`:

```bash
GW=arn:aws:bedrock-agentcore:<region>:<account>:gateway/<gateway-id>
python3 - "$GW" guardrail-tool-input-email.cedar policy > def.json <<'PY'
import json, sys
gw, path, key = sys.argv[1:]
print(json.dumps({key: {"statement": open(path).read().replace("GATEWAY_ARN_PLACEHOLDER", gw)}}))
PY
aws bedrock-agentcore-control create-policy --region <region> \
  --policy-engine-id <engine-id> --name guardrail_greet_email_input \
  --enforcement-mode ACTIVE --validation-mode IGNORE_ALL_FINDINGS \
  --definition file://def.json
# CreatePolicy returns CREATING; check ~15 s later:
aws bedrock-agentcore-control get-policy --region <region> --policy-engine-id <engine-id> \
  --policy-id <policy-id> --query '{status:status,reasons:statusReasons}'
```

## Rules learned the hard way

- **Keep policies in step with target names.** A policy naming an action that no longer
  exists (after a rename) turns off `tools/list` filtering: every tool is listed again,
  although calls are still enforced.
- **Semantic findings are not errors.** "Overly Permissive" (a permit for any principal)
  and "Overly Restrictive" (a forbid on something nothing permits) fail creation unless
  `IGNORE_ALL_FINDINGS` is set. Action names are still validated in that mode.
- **A failed create keeps its name.** Retrying the same name returns `ConflictException`
  until the failed policy is deleted.
- **Guardrail arguments must be string fields.** Lists of records, such as chat
  `messages`, are rejected.
