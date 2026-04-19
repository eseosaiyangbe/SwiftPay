#!/bin/bash
# ============================================
# Build all SwiftPay service images and push to ECR
# ============================================
# Use after code changes so the cluster runs the new code.
# ECR repos are created by Terraform (spoke-vpc-eks); run spinup.sh first if missing.
#
# Usage: ./scripts/build-push-ecr.sh [IMAGE_TAG]
#        IMAGE_TAG=v7 ./scripts/build-push-ecr.sh
# Default tag: latest (or pass e.g. v7 for immutable releases)
#
# Then deploy: cd k8s/overlays/eks && IMAGE_TAG=v7 ./deploy.sh

set -e

IMAGE_TAG="${1:-${IMAGE_TAG:-latest}}"
REGION="${AWS_REGION:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ECR repo name matches Terraform EKS module (swiftpay-eks-cluster)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-swiftpay-eks-cluster}"

echo "Build context: $REPO_ROOT/services"
echo "Image tag: $IMAGE_TAG"
echo "Region: $REGION"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) || {
  echo "Error: AWS CLI not configured or no permission. Run: aws configure"
  exit 1
}

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
echo "ECR registry: $REGISTRY"
echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
echo ""

# All builds use context ./services so shared/ and service code are included
SERVICES=(api-gateway auth-service wallet-service transaction-service notification-service frontend)

for svc in "${SERVICES[@]}"; do
  echo "Building $svc..."
  docker build -f "services/${svc}/Dockerfile" -t "${REGISTRY}/${EKS_CLUSTER_NAME}/${svc}:${IMAGE_TAG}" ./services
  echo "Pushing ${REGISTRY}/${EKS_CLUSTER_NAME}/${svc}:${IMAGE_TAG}"
  docker push "${REGISTRY}/${EKS_CLUSTER_NAME}/${svc}:${IMAGE_TAG}"
  echo "Done: $svc"
  echo ""
done

echo "All images built and pushed."
echo ""
echo "Deploy with:"
echo "  cd k8s/overlays/eks && IMAGE_TAG=${IMAGE_TAG} ./deploy.sh"
echo ""
