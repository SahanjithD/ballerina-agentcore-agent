#!/usr/bin/env bash
# Interactive chat with the deployed agent.  Usage: ./06-chat.sh
#
# Unlike 04-invoke.sh, which mints a fresh session id per run, this keeps ONE session
# id for the whole conversation. That matters: AgentCore routes a session to the same
# container, and `service.bal` passes the session id to `ai:Agent.run` as its memory
# key -- so reusing it is what gives the agent any memory of what you just said.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID="${ACCOUNT_ID:-}"   # not needed here, but keeps config.env consistent

ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeArn | [0]" --output text)

if [ -z "${ARN}" ] || [ "${ARN}" = "None" ]; then
  echo "No runtime named ${AGENT_NAME} in ${AWS_REGION}." >&2
  exit 1
fi

# AgentCore requires at least 33 characters.
SESSION_ID="${SESSION_ID:-$(uuidgen)$(uuidgen)}"

RESP=$(mktemp)
trap 'rm -f "${RESP}"' EXIT

printf 'agent   %s\n' "${AGENT_NAME}"
printf 'session %s\n' "${SESSION_ID}"
printf 'Type your message. Ctrl-D or "exit" to quit.\n\n'

while true; do
  printf '\033[1myou >\033[0m '
  if ! IFS= read -r PROMPT; then echo; break; fi
  [ -z "${PROMPT}" ] && continue
  case "${PROMPT}" in exit|quit) break;; esac

  # Build the payload in python so quotes and newlines in the prompt survive.
  PAYLOAD=$(PROMPT="${PROMPT}" python3 -c 'import json,os; print(json.dumps({"prompt": os.environ["PROMPT"]}))')

  if ! aws bedrock-agentcore invoke-agent-runtime \
        --region "${AWS_REGION}" \
        --agent-runtime-arn "${ARN}" \
        --runtime-session-id "${SESSION_ID}" \
        --content-type application/json \
        --accept application/json \
        --cli-binary-format raw-in-base64-out \
        --payload "${PAYLOAD}" \
        "${RESP}" >/dev/null 2>"${RESP}.err"; then
    printf '\033[31magent> invoke failed:\033[0m %s\n\n' "$(tr -d '\n' < "${RESP}.err")"
    continue
  fi

  # The runtime returns {"response": "...", "status": "..."}; print just the prose,
  # and fall back to the raw body if it is shaped differently (e.g. an error).
  python3 - "${RESP}" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
try:
    body = json.loads(raw)
except json.JSONDecodeError:
    print("\033[31magent>\033[0m " + raw.strip() + "\n")
    sys.exit()
text = body.get("response") or body.get("message") or json.dumps(body, indent=2)
print("\033[36magent>\033[0m " + text + "\n")
PY
done

printf '\nSession %s ended.\n' "${SESSION_ID}"
