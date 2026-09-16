#!/usr/bin/env bash
# Promotes the policy engine from LOG_ONLY to ENFORCE.
#
# ENFORCE is default-deny: any tool call not matched by a permit policy is rejected.
# Run this only after confirming in LOG_ONLY that the baseline permit covers every
# target on the gateway. To back out, re-run 40-create-policy-engine.sh, which
# re-attaches in LOG_ONLY.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ENGINE_NAME="${POLICY_ENGINE_NAME:-ballerina_agent_policies}"

ENGINE_ID=$(aws bedrock-agentcore-control list-policy-engines --region "${AWS_REGION}" \
  --query "items[?name=='${ENGINE_NAME}'].policyEngineId | [0]" --output text)
ENGINE_ARN=$(aws bedrock-agentcore-control get-policy-engine --region "${AWS_REGION}" \
  --policy-engine-id "${ENGINE_ID}" --query policyEngineArn --output text)

read -r -p "Switch ${ENGINE_NAME} to ENFORCE on ${GATEWAY_ID}? [y/N] " CONFIRM
case "${CONFIRM}" in y|Y) ;; *) echo "Aborted."; exit 0;; esac

aws bedrock-agentcore-control update-gateway --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" \
  --policy-engine-configuration "{\"arn\":\"${ENGINE_ARN}\",\"mode\":\"ENFORCE\"}" >/dev/null

echo "ENFORCE is on. Verify immediately that deepwiki and weather still work."
