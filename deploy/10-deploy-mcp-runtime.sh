#!/usr/bin/env bash
# Deploys the Ballerina MCP server (tools/mcp-server) to its own AgentCore Runtime.
#
# AgentCore Runtime hosts MCP servers natively: set serverProtocol to MCP and the
# platform expects streamable HTTP on 0.0.0.0:8000/mcp. Nothing about that contract
# is language-specific, so the Ballerina container satisfies it the same way a
# Python one would.
#
# Unlike the agent runtime, this one carries no secrets at all -- the tools are pure
# functions, so there is no API key to hand it.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

# STS is only needed to learn the account id. Export ACCOUNT_ID to skip the call --
# useful when the STS endpoint is blocked but ECR is reachable.
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${MCP_ECR_REPO}:${IMAGE_TAG}"

# 01-create-role.sh reads AGENT_NAME/EXECUTION_ROLE_NAME from the environment, so
# overriding them here reuses it verbatim for this runtime's execution role.
echo "==> Execution role"
AGENT_NAME="${MCP_AGENT_NAME}" EXECUTION_ROLE_NAME="${MCP_EXECUTION_ROLE_NAME}" ./01-create-role.sh

echo "==> Image"
aws ecr describe-repositories --repository-names "${MCP_ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${MCP_ECR_REPO}" --region "${AWS_REGION}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# AgentCore Runtime only accepts arm64 images.
# --provenance=false is required, not optional. buildx otherwise emits an
# attestation manifest alongside an OCI manifest list, and both AgentCore Runtime
# and Lambda reject that shape -- AgentCore with an unhelpful error, Lambda with
# "image manifest ... not supported". The flag forces a single plain manifest.
docker buildx build --provenance=false --platform linux/arm64 \
  -t "${IMAGE_URI}" --push ../tools/mcp-server

ROLE_ARN=$(aws iam get-role --role-name "${MCP_EXECUTION_ROLE_NAME}" --query Role.Arn --output text)

EXISTING_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${MCP_AGENT_NAME}'].agentRuntimeId | [0]" --output text)

REQUEST=$(mktemp)                 # mktemp creates the file 0600
trap 'rm -f "${REQUEST}"' EXIT

IMAGE_URI="${IMAGE_URI}" ROLE_ARN="${ROLE_ARN}" MCP_AGENT_NAME="${MCP_AGENT_NAME}" \
EXISTING_ID="${EXISTING_ID}" \
python3 > "${REQUEST}" <<'PY'
import json, os

existing = os.environ["EXISTING_ID"]
body = {
    "agentRuntimeArtifact": {"containerConfiguration": {"containerUri": os.environ["IMAGE_URI"]}},
    "roleArn": os.environ["ROLE_ARN"],
    "networkConfiguration": {"networkMode": "PUBLIC"},
    # The one setting that makes this an MCP server rather than an agent.
    "protocolConfiguration": {"serverProtocol": "MCP"},
}
if existing in ("", "None"):
    body["agentRuntimeName"] = os.environ["MCP_AGENT_NAME"]
else:
    body["agentRuntimeId"] = existing
print(json.dumps(body))
PY

echo "==> Runtime"
if [ "${EXISTING_ID}" = "None" ] || [ -z "${EXISTING_ID}" ]; then
  echo "Creating MCP runtime ${MCP_AGENT_NAME}..."
  aws bedrock-agentcore-control create-agent-runtime \
    --region "${AWS_REGION}" --cli-input-json "file://${REQUEST}"
else
  echo "Updating MCP runtime ${MCP_AGENT_NAME} (${EXISTING_ID})..."
  aws bedrock-agentcore-control update-agent-runtime \
    --region "${AWS_REGION}" --cli-input-json "file://${REQUEST}"
fi

ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${MCP_AGENT_NAME}'].agentRuntimeArn | [0]" --output text)
echo
echo "Runtime ARN: ${ARN}"
echo "Gateway target endpoint:"
echo "  https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/$(python3 -c '
import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${ARN}")/invocations?qualifier=DEFAULT"
