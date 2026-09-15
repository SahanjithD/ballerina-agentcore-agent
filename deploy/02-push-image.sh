#!/usr/bin/env bash
# Builds the linux/arm64 image and pushes it to ECR.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

# STS is only needed to learn the account id. Export ACCOUNT_ID to skip the call --
# useful when the STS endpoint is blocked but ECR is reachable.
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# AgentCore Runtime only accepts arm64 images.
# --provenance=false is required, not optional. buildx otherwise emits an
# attestation manifest alongside an OCI manifest list, and both AgentCore Runtime
# and Lambda reject that shape -- AgentCore with an unhelpful error, Lambda with
# "image manifest ... not supported". The flag forces a single plain manifest.
docker buildx build --provenance=false --platform linux/arm64 \
  -t "${IMAGE_URI}" --push ..

echo "Image: ${IMAGE_URI}"
