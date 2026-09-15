#!/usr/bin/env bash
# Builds and pushes both tool images to ECR, then prints the URIs to paste into the
# console. This is the only part of the setup the console cannot do for you -- it
# has no way to build a Ballerina package.
#
# Everything after this (runtime, Lambda, gateway targets) can be done in the console;
# see DEPLOY.md. 10-deploy-mcp-runtime.sh and 20-deploy-rest-lambda.sh do the same
# work from the CLI instead, if you would rather not click.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

# STS is only needed to learn the account id. Export ACCOUNT_ID to skip the call --
# useful when the STS endpoint is blocked but ECR is reachable.
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

for pair in "${MCP_ECR_REPO}:../tools/mcp-server" "${REST_ECR_REPO}:../tools/rest-api"; do
  repo="${pair%%:*}"
  context="${pair#*:}"
  echo
  echo "==> ${repo}"
  # Creating the repo needs ecr:CreateRepository, which a push-scoped user often does
  # not have. Missing it is not fatal -- someone else can create the repo -- so say so
  # plainly rather than failing with a raw AccessDeniedException.
  if ! aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    if ! aws ecr create-repository --repository-name "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      cat >&2 <<EOF

Repository ${repo} does not exist and this identity cannot create it.
Create it with an identity that can, then re-run this script:

  aws ecr create-repository --repository-name ${repo} --region ${AWS_REGION}

or in the console: ECR > Private registry > Repositories > Create.
EOF
      exit 1
    fi
  fi
  # arm64 for both: AgentCore Runtime accepts nothing else, and the Lambda function
  # must be created with --architectures arm64 to match.
  # --provenance=false is required, not optional. buildx otherwise emits an
  # attestation manifest alongside an OCI manifest list, and both AgentCore Runtime
  # and Lambda reject that shape -- AgentCore with an unhelpful error, Lambda with
  # "image manifest ... not supported". The flag forces a single plain manifest.
  docker buildx build --provenance=false --platform linux/arm64 \
    -t "${REGISTRY}/${repo}:${IMAGE_TAG}" --push "${context}"
done

cat <<EOF

────────────────────────────────────────────────────────────────
Paste these into the console:

  MCP server image (AgentCore Runtime, protocol MCP, arm64)
    ${REGISTRY}/${MCP_ECR_REPO}:${IMAGE_TAG}

  REST API image (Lambda, container image, arm64)
    ${REGISTRY}/${REST_ECR_REPO}:${IMAGE_TAG}
────────────────────────────────────────────────────────────────
EOF
