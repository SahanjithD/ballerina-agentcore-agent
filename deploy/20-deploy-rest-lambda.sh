#!/usr/bin/env bash
# Deploys the Ballerina REST API (tools/rest-api) as a Lambda container image behind
# a Function URL, and rewrites the OpenAPI spec's server URL to match.
#
# Why Lambda rather than AgentCore: the Runtime HTTP contract mounts only /invocations
# and /ws, so arbitrary REST paths like /v1/greet/{name} are unreachable there. A
# Function URL gives a publicly trusted *.lambda-url.<region>.on.aws certificate with
# no domain, ACM or load balancer, and -- unlike an ALB -- it verifies SigV4 natively,
# which is what lets the gateway authenticate as its own IAM role in 30-add-gateway-targets.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

# STS is only needed to learn the account id. Export ACCOUNT_ID to skip the call --
# useful when the STS endpoint is blocked but ECR is reachable.
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REST_ECR_REPO}:${IMAGE_TAG}"

echo "==> Execution role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "${REST_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${REST_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST}" \
    --description "Execution role for ${REST_FUNCTION_NAME}" >/dev/null
fi
# CloudWatch Logs only; the service talks to nothing else.
aws iam attach-role-policy --role-name "${REST_ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
ROLE_ARN=$(aws iam get-role --role-name "${REST_ROLE_NAME}" --query Role.Arn --output text)

echo "==> Image"
aws ecr describe-repositories --repository-names "${REST_ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${REST_ECR_REPO}" --region "${AWS_REGION}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# arm64 to match the --architectures flag below; the two must agree or Lambda
# rejects the image with a mismatch error at create time.
# --provenance=false is required, not optional. buildx otherwise emits an
# attestation manifest alongside an OCI manifest list, and both AgentCore Runtime
# and Lambda reject that shape -- AgentCore with an unhelpful error, Lambda with
# "image manifest ... not supported". The flag forces a single plain manifest.
docker buildx build --provenance=false --platform linux/arm64 \
  -t "${IMAGE_URI}" --push ../tools/rest-api

echo "==> Function"
if aws lambda get-function --function-name "${REST_FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${REST_FUNCTION_NAME}" \
    --region "${AWS_REGION}" --image-uri "${IMAGE_URI}" >/dev/null
  aws lambda wait function-updated --function-name "${REST_FUNCTION_NAME}" --region "${AWS_REGION}"
else
  # The JVM needs headroom and a generous cold-start budget: a Ballerina jar takes
  # a few seconds to reach the listener, and the adapter holds the request until
  # its readiness probe passes.
  aws lambda create-function --function-name "${REST_FUNCTION_NAME}" \
    --region "${AWS_REGION}" \
    --package-type Image \
    --code "ImageUri=${IMAGE_URI}" \
    --role "${ROLE_ARN}" \
    --architectures arm64 \
    --timeout 60 \
    --memory-size 1024 >/dev/null
  aws lambda wait function-active --function-name "${REST_FUNCTION_NAME}" --region "${AWS_REGION}"
fi

echo "==> Function URL"
# AWS_IAM, not NONE: the gateway signs its calls with SigV4, and this keeps the
# endpoint from being open to the internet.
aws lambda get-function-url-config --function-name "${REST_FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws lambda create-function-url-config --function-name "${REST_FUNCTION_NAME}" \
       --region "${AWS_REGION}" --auth-type AWS_IAM >/dev/null

FUNCTION_URL=$(aws lambda get-function-url-config --function-name "${REST_FUNCTION_NAME}" \
  --region "${AWS_REGION}" --query FunctionUrl --output text)
HOST=$(printf '%s' "${FUNCTION_URL}" | sed -e 's|^https://||' -e 's|/$||')

# Bake the real host into the spec that 30-add-gateway-targets.sh uploads. Gateway
# requires a static, fully qualified URL in `servers`.
sed -i.bak "s|url: https://.*/v1$|url: https://${HOST}/v1|" ../gateway/tools-api-openapi.yaml
rm -f ../gateway/tools-api-openapi.yaml.bak

echo
echo "Function URL: ${FUNCTION_URL}"
echo "gateway/tools-api-openapi.yaml server URL set to https://${HOST}/v1"
