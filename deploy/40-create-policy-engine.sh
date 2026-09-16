#!/usr/bin/env bash
# Creates a Policy engine, loads the Cedar policies from policy/, and attaches the
# engine to the gateway in LOG_ONLY mode.
#
# LOG_ONLY deliberately: ENFORCE is DEFAULT-DENY, so switching it on before you have
# confirmed the baseline permit covers every target takes down deepwiki, weather and
# the Ballerina tools at once. In LOG_ONLY the engine evaluates every call and records
# what it *would* have decided, changing nothing. Promote to ENFORCE with 41-enforce.sh
# once the traces look right.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ENGINE_NAME="${POLICY_ENGINE_NAME:-ballerina_agent_policies}"
GATEWAY_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${ACCOUNT_ID}:gateway/${GATEWAY_ID}"

echo "==> Gateway ${GATEWAY_ARN}"

# Cedar action names are "<targetName>___<toolName>". Print the real list so the
# policies can be checked against it rather than guessed at.
echo
echo "==> Tool names currently exposed by the gateway"
aws bedrock-agentcore-control list-gateway-targets --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" \
  --query 'items[].name' --output text 2>/dev/null \
  || echo "   (could not list targets -- check the action names by hand)"

echo
echo "==> Policy engine"
EXISTING=$(aws bedrock-agentcore-control list-policy-engines --region "${AWS_REGION}" \
  --query "items[?name=='${ENGINE_NAME}'].policyEngineId | [0]" --output text 2>/dev/null || echo "None")

if [ "${EXISTING}" = "None" ] || [ -z "${EXISTING}" ]; then
  ENGINE_ID=$(aws bedrock-agentcore-control create-policy-engine \
    --region "${AWS_REGION}" --name "${ENGINE_NAME}" \
    --description "Cedar policies governing tool calls through ${GATEWAY_ID}" \
    --query policyEngineId --output text)
  echo "Created ${ENGINE_ID}"
else
  ENGINE_ID="${EXISTING}"
  echo "Reusing ${ENGINE_ID}"
fi

ENGINE_ARN=$(aws bedrock-agentcore-control get-policy-engine --region "${AWS_REGION}" \
  --policy-engine-id "${ENGINE_ID}" --query policyEngineArn --output text)

echo
echo "==> Policies"
for FILE in ../policy/*.cedar; do
  NAME=$(basename "${FILE}" .cedar | tr '-' '_')
  # The gateway ARN cannot be a wildcard in Cedar, so it is substituted in here rather
  # than committed into the .cedar files.
  STATEMENT=$(sed "s|GATEWAY_ARN_PLACEHOLDER|${GATEWAY_ARN}|g" "${FILE}")

  DEFINITION=$(STATEMENT="${STATEMENT}" python3 -c '
import json, os
print(json.dumps({"cedar": {"statement": os.environ["STATEMENT"]}}))')

  echo "   ${NAME}"
  aws bedrock-agentcore-control create-policy \
    --region "${AWS_REGION}" \
    --policy-engine-id "${ENGINE_ID}" \
    --name "${NAME}" \
    --definition "${DEFINITION}" >/dev/null \
    || echo "     (already exists, or validation rejected it -- see above)"
done

echo
echo "==> Attaching engine to gateway in LOG_ONLY"
aws bedrock-agentcore-control update-gateway --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" \
  --policy-engine-configuration "{\"arn\":\"${ENGINE_ARN}\",\"mode\":\"LOG_ONLY\"}" >/dev/null

cat <<EOF

Engine ${ENGINE_ARN}
Mode   LOG_ONLY  (evaluating, not enforcing)

Next: exercise the agent, then look at what the engine would have decided:

  aws logs tail aws/spans --region ${AWS_REGION} --since 15m | grep -i policy

When the decisions look right, switch on enforcement with ./41-enforce.sh
EOF
