#!/usr/bin/env bash
# =============================================================================
# PayFlow EKS Deploy Script
# =============================================================================
# Usage:
#   IMAGE_TAG=<git-sha>  ./deploy.sh          # deploy specific image tag (recommended)
#   IMAGE_TAG=latest     ./deploy.sh          # deploy latest (not recommended for prod)
#
# Prerequisites:
#   - kubectl configured against the EKS cluster (via bastion SSH tunnel or direct)
#   - AWS credentials set (aws configure or env vars)
#   - IMAGE_TAG matches a tag pushed to ECR by the CI pipeline
#
# What this script does:
#   1. Resolves the AWS account ID and region from the current AWS session.
#   2. Substitutes the <ACCOUNT_ID>, <REGION>, and <IMAGE_TAG> placeholders in
#      kustomization.yaml (without permanently modifying the file).
#   3. Runs kubectl apply -k with the substituted config piped via stdin.
# =============================================================================
set -euo pipefail

# ---- Resolve placeholders ----
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

if [[ "$IMAGE_TAG" == "latest" ]]; then
  echo "WARNING: Deploying :latest tag. For production, set IMAGE_TAG to a specific git SHA."
fi

echo "Deploying PayFlow to EKS"
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $REGION"
echo "  Tag     : $IMAGE_TAG"
echo "  Cluster : ${EKS_CLUSTER_NAME:-payflow-eks-cluster}"
echo ""

# ---- Update kubeconfig (no-op if already configured) ----
aws eks update-kubeconfig \
  --region "$REGION" \
  --name "${EKS_CLUSTER_NAME:-payflow-eks-cluster}" \
  --no-cli-pager 2>/dev/null || true

# ---- Apply kustomization with placeholders replaced on the fly ----
# sed replaces placeholders in a temporary copy piped to kubectl.
# The actual kustomization.yaml is never modified; placeholders stay as-is for re-use.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sed \
  -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
  -e "s|<REGION>|${REGION}|g" \
  -e "s|<IMAGE_TAG>|${IMAGE_TAG}|g" \
  "$DIR/kustomization.yaml" \
| kubectl apply -k - --namespace payflow

echo ""
echo "Deploy complete. Watching rollout status..."
for svc in api-gateway auth-service wallet-service transaction-service notification-service frontend; do
  kubectl rollout status deployment/"$svc" -n payflow --timeout=180s || true
done

echo ""
echo "Current pods:"
kubectl get pods -n payflow
