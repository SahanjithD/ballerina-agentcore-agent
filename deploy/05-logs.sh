#!/usr/bin/env bash
# Tails the runtime's CloudWatch logs.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeId | [0]" --output text)

aws logs tail "/aws/bedrock-agentcore/runtimes/${ID}-DEFAULT" \
  --region "${AWS_REGION}" --follow
