#!/usr/bin/env bash
# Attaches both Ballerina backends to the AgentCore Gateway as targets, and grants the
# gateway the IAM permissions it needs to reach them.
#
# Both targets use GATEWAY_IAM_ROLE outbound auth: the gateway signs its calls with
# SigV4 as its own execution role. That works here only because both backends sit
# behind AWS services that verify SigV4 natively -- AgentCore Runtime and Lambda
# Function URLs. (An ALB or a bare EC2 endpoint cannot, and would need OAuth or an
# API key credential provider instead.) The payoff is that no shared secret exists
# anywhere in this path: nothing to store, rotate, or leak.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

if [ -z "${GATEWAY_ID}" ]; then
  echo "Set GATEWAY_ID in deploy/config.env (e.g. ballerina-agent-gatewa-01gzl3luj1)." >&2
  echo "List them with: aws bedrock-agentcore-control list-gateways --region ${AWS_REGION}" >&2
  exit 1
fi

# STS is only needed to learn the account id. Export ACCOUNT_ID to skip the call --
# useful when the STS endpoint is blocked but ECR is reachable.
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

GATEWAY_ROLE_ARN=$(aws bedrock-agentcore-control get-gateway --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" --query roleArn --output text)
GATEWAY_ROLE_NAME="${GATEWAY_ROLE_ARN##*/}"
GATEWAY_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${ACCOUNT_ID}:gateway/${GATEWAY_ID}"

MCP_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${MCP_AGENT_NAME}'].agentRuntimeArn | [0]" --output text)
FUNCTION_ARN=$(aws lambda get-function --function-name "${REST_FUNCTION_NAME}" \
  --region "${AWS_REGION}" --query Configuration.FunctionArn --output text)

echo "Gateway role: ${GATEWAY_ROLE_NAME}"
echo "MCP runtime:  ${MCP_RUNTIME_ARN}"
echo "REST lambda:  ${FUNCTION_ARN}"

echo
echo "==> Outbound permissions for the gateway role"
OUTBOUND_POLICY=$(MCP_RUNTIME_ARN="${MCP_RUNTIME_ARN}" FUNCTION_ARN="${FUNCTION_ARN}" python3 <<'PY'
import json, os
print(json.dumps({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "InvokeBallerinaMcpRuntime",
            "Effect": "Allow",
            "Action": ["bedrock-agentcore:InvokeAgentRuntime"],
            "Resource": [os.environ["MCP_RUNTIME_ARN"], os.environ["MCP_RUNTIME_ARN"] + "/*"],
        },
        {
            "Sid": "InvokeBallerinaRestFunctionUrl",
            "Effect": "Allow",
            "Action": ["lambda:InvokeFunctionUrl"],
            "Resource": [os.environ["FUNCTION_ARN"]],
        },
    ],
}))
PY
)
aws iam put-role-policy --role-name "${GATEWAY_ROLE_NAME}" \
  --policy-name "BallerinaToolTargets" --policy-document "${OUTBOUND_POLICY}"

# The function URL needs a resource policy too: identity-based permission alone does
# not authorise a Function URL call.
aws lambda add-permission --function-name "${REST_FUNCTION_NAME}" --region "${AWS_REGION}" \
  --statement-id AllowAgentCoreGateway \
  --action lambda:InvokeFunctionUrl \
  --principal "${GATEWAY_ROLE_ARN}" \
  --function-url-auth-type AWS_IAM >/dev/null 2>&1 \
  || echo "   (resource policy statement already present)"

echo
echo "==> MCP server target"
MCP_ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/$(python3 -c '
import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${MCP_RUNTIME_ARN}")/invocations?qualifier=DEFAULT"
echo "    ${MCP_ENDPOINT}"

MCP_REQUEST=$(mktemp); trap 'rm -f "${MCP_REQUEST}" "${API_REQUEST:-}"' EXIT
GATEWAY_ID="${GATEWAY_ID}" MCP_ENDPOINT="${MCP_ENDPOINT}" AWS_REGION="${AWS_REGION}" \
python3 > "${MCP_REQUEST}" <<'PY'
import json, os
print(json.dumps({
    "gatewayIdentifier": os.environ["GATEWAY_ID"],
    "name": "ballerinaMcpServer",
    "description": "Ballerina MCP server on AgentCore Runtime",
    "targetConfiguration": {
        "mcp": {
            "mcpServer": {
                "endpoint": os.environ["MCP_ENDPOINT"],
                # DEFAULT: the gateway calls tools/list once now and caches the catalog.
                # Re-run SynchronizeGatewayTargets after changing the server's tools.
                "listingMode": "DEFAULT",
            }
        }
    },
    "credentialProviderConfigurations": [{
        "credentialProviderType": "GATEWAY_IAM_ROLE",
        "credentialProvider": {
            "iamCredentialProvider": {
                "service": "bedrock-agentcore",
                "region": os.environ["AWS_REGION"],
            }
        },
    }],
}))
PY
aws bedrock-agentcore-control create-gateway-target \
  --region "${AWS_REGION}" --cli-input-json "file://${MCP_REQUEST}"

echo
echo "==> OpenAPI target"
SPEC=../gateway/tools-api-openapi.yaml
if grep -q REPLACE_WITH_FUNCTION_URL "${SPEC}"; then
  echo "${SPEC} still has the placeholder server URL -- run ./20-deploy-rest-lambda.sh first." >&2
  exit 1
fi

API_REQUEST=$(mktemp)
GATEWAY_ID="${GATEWAY_ID}" SPEC="${SPEC}" AWS_REGION="${AWS_REGION}" \
python3 > "${API_REQUEST}" <<'PY'
import json, os
# The spec goes across as an opaque string, so YAML needs no conversion here.
with open(os.environ["SPEC"]) as f:
    spec = f.read()
print(json.dumps({
    "gatewayIdentifier": os.environ["GATEWAY_ID"],
    "name": "ballerinaRestApi",
    "description": "Ballerina REST API on Lambda, behind a Function URL",
    "targetConfiguration": {"mcp": {"openApiSchema": {"inlinePayload": spec}}},
    "credentialProviderConfigurations": [{
        "credentialProviderType": "GATEWAY_IAM_ROLE",
        "credentialProvider": {
            "iamCredentialProvider": {
                "service": "lambda",
                "region": os.environ["AWS_REGION"],
            }
        },
    }],
}))
PY
aws bedrock-agentcore-control create-gateway-target \
  --region "${AWS_REGION}" --cli-input-json "file://${API_REQUEST}"

echo
echo "Done. The agent picks the new tools up on its next restart -- ai:McpToolKit"
echo "calls listTools in its init, so the tool list is fixed when the container boots."
