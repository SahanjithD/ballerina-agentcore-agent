#!/usr/bin/env bash
# Creates (or updates) the AgentCore Runtime execution role.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ${ACCOUNT_ID}, region ${AWS_REGION}, role ${EXECUTION_ROLE_NAME}"

TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AssumeRolePolicy",
    "Effect": "Allow",
    "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:${AWS_REGION}:${ACCOUNT_ID}:*" }
    }
  }]
}
JSON
)

POLICY=$(sed -e "s/{{ACCOUNT_ID}}/${ACCOUNT_ID}/g" \
             -e "s/{{REGION}}/${AWS_REGION}/g" \
             -e "s/{{AGENT_NAME}}/${AGENT_NAME}/g" execution-policy.json)

if aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${EXECUTION_ROLE_NAME}" \
    --policy-document "${TRUST}"
else
  aws iam create-role --role-name "${EXECUTION_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST}" \
    --description "Execution role for AgentCore runtime ${AGENT_NAME}" >/dev/null
fi

aws iam put-role-policy --role-name "${EXECUTION_ROLE_NAME}" \
  --policy-name "AgentCoreRuntimeExecution" \
  --policy-document "${POLICY}"

ROLE_ARN=$(aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query Role.Arn --output text)
echo "Role ARN: ${ROLE_ARN}"
