#!/usr/bin/env bash
# Invokes the deployed agent.  Usage: ./04-invoke.sh "your prompt"
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

PROMPT="${1:-What is 8 plus 9, multiplied by 10?}"
# AgentCore requires a runtime session id of at least 33 characters.
SESSION_ID="${SESSION_ID:-$(uuidgen)$(uuidgen)}"

ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeArn | [0]" --output text)

PAYLOAD=$(PROMPT="${PROMPT}" python3 -c 'import json,os; print(json.dumps({"prompt": os.environ["PROMPT"]}))')

# --payload is a blob; AWS CLI v2 needs raw-in-base64-out to accept raw JSON.
aws bedrock-agentcore invoke-agent-runtime \
  --region "${AWS_REGION}" \
  --agent-runtime-arn "${ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --content-type application/json \
  --accept application/json \
  --cli-binary-format raw-in-base64-out \
  --payload "${PAYLOAD}" \
  /dev/stdout
