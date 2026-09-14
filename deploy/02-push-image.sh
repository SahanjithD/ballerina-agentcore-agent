#!/usr/bin/env bash
# Builds the linux/arm64 image and pushes it to ECR.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# AgentCore Runtime only accepts arm64 images.
docker buildx build --platform linux/arm64 -t "${IMAGE_URI}" --push ..

echo "Image: ${IMAGE_URI}"
