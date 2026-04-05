#!/usr/bin/env bash
# =============================================================================
# PayFlow AKS Deploy Script
# =============================================================================
# Usage:
#   IMAGE_TAG=<git-sha>  ./deploy.sh          # deploy specific image tag (recommended)
#   IMAGE_TAG=latest     ./deploy.sh          # deploy latest (not recommended for prod)
#   ACR_NAME=myregistry  IMAGE_TAG=abc1234 ./deploy.sh
#
# Prerequisites:
#   - kubectl configured against the AKS cluster
#       az aks get-credentials --resource-group payflow-rg --name payflow-aks
#   - Azure CLI logged in (az login) with access to the ACR
#   - IMAGE_TAG matches a tag pushed to ACR by the CI pipeline
#
# What this script does:
#   1. Resolves ACR_NAME from the environment or az CLI if not set.
#   2. Substitutes <ACR_NAME> and <IMAGE_TAG> placeholders in kustomization.yaml
#      (without permanently modifying the file — piped via stdin to kubectl).
#   3. Runs kubectl apply -k and watches rollout status for all six services.
# =============================================================================
set -euo pipefail

# ---- Resolve ACR name ----
if [[ -z "${ACR_NAME:-}" ]]; then
  echo "ACR_NAME not set — attempting to discover from az CLI..."
  ACR_NAME=$(az acr list --query "[?contains(name, 'payflow')].name" -o tsv 2>/dev/null | head -1)
  if [[ -z "$ACR_NAME" ]]; then
    echo "ERROR: Could not determine ACR_NAME. Set it explicitly:"
    echo "  ACR_NAME=myregistry IMAGE_TAG=abc1234 ./deploy.sh"
    exit 1
  fi
fi

IMAGE_TAG="${IMAGE_TAG:-latest}"

if [[ "$IMAGE_TAG" == "latest" ]]; then
  echo "WARNING: Deploying :latest tag. For production, set IMAGE_TAG to a specific git SHA."
fi

echo "Deploying PayFlow to AKS"
echo "  ACR       : $ACR_NAME"
echo "  Tag       : $IMAGE_TAG"
echo ""

# ---- Apply kustomization with placeholders replaced on the fly ----
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sed \
  -e "s|<ACR_NAME>|${ACR_NAME}|g" \
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
