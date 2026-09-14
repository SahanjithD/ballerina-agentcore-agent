#!/usr/bin/env bash
# Creates the AgentCore runtime, or updates it if it already exists.
#
# The Anthropic API key is read from Secrets Manager and passed to the runtime
# as the environment variable Ballerina uses for the `anthropicApiKey`
# configurable: BAL_CONFIG_VAR_ + the variable name, uppercased.
#
# The request is sent via --cli-input-json from a 0600 temp file so the key
# never appears in the process list.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
ROLE_ARN=$(aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query Role.Arn --output text)

ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "${ANTHROPIC_SECRET_NAME}" --region "${AWS_REGION}" \
  --query SecretString --output text)

EXISTING_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeId | [0]" --output text)

REQUEST=$(mktemp)                 # mktemp creates the file 0600
trap 'rm -f "${REQUEST}"' EXIT

# Build the request body in python so the key is never interpolated by the
# shell; it reaches python through the environment, not argv.
IMAGE_URI="${IMAGE_URI}" ROLE_ARN="${ROLE_ARN}" AGENT_NAME="${AGENT_NAME}" \
EXISTING_ID="${EXISTING_ID}" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
python3 > "${REQUEST}" <<'PY'
import json, os

existing = os.environ["EXISTING_ID"]
body = {
    "agentRuntimeArtifact": {"containerConfiguration": {"containerUri": os.environ["IMAGE_URI"]}},
    "roleArn": os.environ["ROLE_ARN"],
    "networkConfiguration": {"networkMode": "PUBLIC"},
    "protocolConfiguration": {"serverProtocol": "HTTP"},
    "environmentVariables": {"BAL_CONFIG_VAR_ANTHROPICAPIKEY": os.environ["ANTHROPIC_API_KEY"]},
}
if existing in ("", "None"):
    body["agentRuntimeName"] = os.environ["AGENT_NAME"]
else:
    body["agentRuntimeId"] = existing
print(json.dumps(body))
PY

if [ "${EXISTING_ID}" = "None" ] || [ -z "${EXISTING_ID}" ]; then
  echo "Creating runtime ${AGENT_NAME}..."
  aws bedrock-agentcore-control create-agent-runtime \
    --region "${AWS_REGION}" --cli-input-json "file://${REQUEST}"
else
  echo "Updating runtime ${AGENT_NAME} (${EXISTING_ID})..."
  aws bedrock-agentcore-control update-agent-runtime \
    --region "${AWS_REGION}" --cli-input-json "file://${REQUEST}"
fi
