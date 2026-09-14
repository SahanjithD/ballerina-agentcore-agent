#!/usr/bin/env bash
# Creates the AgentCore runtime, or updates it if it already exists.
#
# The Anthropic API key is read from Secrets Manager and passed to the runtime
# as the environment variable Ballerina uses for the `anthropicApiKey`
# configurable (BAL_CONFIG_VAR_ + the variable name, uppercased).
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
ROLE_ARN=$(aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query Role.Arn --output text)

ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "${ANTHROPIC_SECRET_NAME}" --region "${AWS_REGION}" \
  --query SecretString --output text)

ARTIFACT=$(printf '{"containerConfiguration":{"containerUri":"%s"}}' "${IMAGE_URI}")
ENV_VARS=$(printf '{"BAL_CONFIG_VAR_ANTHROPICAPIKEY":"%s"}' "${ANTHROPIC_API_KEY}")

# Build the network configuration.  VPC mode additionally needs the subnets and
# security groups whose ENIs the runtime will use.
if [ "${NETWORK_MODE}" = "VPC" ]; then
  if [ -z "${AGENT_SUBNETS}" ] || [ -z "${AGENT_SECURITY_GROUPS}" ]; then
    echo "NETWORK_MODE=VPC needs AGENT_SUBNETS and AGENT_SECURITY_GROUPS; run ./06-create-vpc.sh first." >&2
    exit 1
  fi
  NETWORK_CONFIG=$(SUBNETS="${AGENT_SUBNETS}" SGS="${AGENT_SECURITY_GROUPS}" python3 -c '
import json, os
print(json.dumps({
    "networkMode": "VPC",
    "networkModeConfig": {
        "subnets": os.environ["SUBNETS"].split(","),
        "securityGroups": os.environ["SGS"].split(","),
    },
}))')
else
  NETWORK_CONFIG='{"networkMode":"PUBLIC"}'
fi

EXISTING_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeId | [0]" --output text)

if [ "${EXISTING_ID}" = "None" ] || [ -z "${EXISTING_ID}" ]; then
  echo "Creating runtime ${AGENT_NAME}..."
  aws bedrock-agentcore-control create-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-name "${AGENT_NAME}" \
    --agent-runtime-artifact "${ARTIFACT}" \
    --role-arn "${ROLE_ARN}" \
    --network-configuration "${NETWORK_CONFIG}" \
    --protocol-configuration '{"serverProtocol":"HTTP"}' \
    --environment-variables "${ENV_VARS}"
else
  echo "Updating runtime ${AGENT_NAME} (${EXISTING_ID})..."
  aws bedrock-agentcore-control update-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-id "${EXISTING_ID}" \
    --agent-runtime-artifact "${ARTIFACT}" \
    --role-arn "${ROLE_ARN}" \
    --network-configuration "${NETWORK_CONFIG}" \
    --protocol-configuration '{"serverProtocol":"HTTP"}' \
    --environment-variables "${ENV_VARS}"
fi
