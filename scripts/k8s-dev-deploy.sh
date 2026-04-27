#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-dev-deploy.sh [options]

Build and deploy the SwiftPay k3s dev overlay to the current Kubernetes context.

Options:
  --skip-runtime  Skip local k3s runtime bootstrap
  --skip-build    Reuse existing local images
  --skip-apply    Only build and validate; do not apply manifests
  --hostname HOST Override frontend ingress hostname validation target
  -h, --help      Show this help message
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
HOSTNAME_OVERRIDE="www.swiftpay.devops.local"
SKIP_RUNTIME=0
SKIP_BUILD=0
SKIP_APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-runtime)
      SKIP_RUNTIME=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-apply)
      SKIP_APPLY=1
      shift
      ;;
    --hostname)
      HOSTNAME_OVERRIDE="${2:?Missing hostname value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ "$SKIP_RUNTIME" -eq 0 ]]; then
  "${WORKSPACE_ROOT}/scripts/ensure-k3s-runtime.sh" >/dev/null
fi

echo "[swiftpay-k8s] Validating kustomize overlay"
kubectl kustomize k8s/overlays/dev >/dev/null
kubectl apply --dry-run=client -k k8s/overlays/dev >/dev/null

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "[swiftpay-k8s] Building local images"
  (
    cd services
    docker build -t swiftpay-api-gateway:dev -f api-gateway/Dockerfile .
    docker build -t swiftpay-auth-service:dev -f auth-service/Dockerfile .
    docker build -t swiftpay-wallet-service:dev -f wallet-service/Dockerfile .
    docker build -t swiftpay-transaction-service:dev -f transaction-service/Dockerfile .
    docker build -t swiftpay-notification-service:dev -f notification-service/Dockerfile .
    docker build -t swiftpay-frontend:dev -f frontend/Dockerfile .
  )
fi

if [[ "$SKIP_APPLY" -eq 1 ]]; then
  echo "[swiftpay-k8s] Skipping apply by request"
  exit 0
fi

echo "[swiftpay-k8s] Applying overlay"
kubectl apply -k k8s/overlays/dev

echo "[swiftpay-k8s] Waiting for infrastructure"
kubectl rollout status statefulset/postgres -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/redis -n swiftpay-dev --timeout=180s
kubectl rollout status deployment/rabbitmq -n swiftpay-dev --timeout=180s

echo "[swiftpay-k8s] Waiting for database migration"
kubectl wait --for=condition=complete job/db-migration-job -n swiftpay-dev --timeout=240s

echo "[swiftpay-k8s] Waiting for services"
kubectl rollout status deployment/api-gateway -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/auth-service -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/wallet-service -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/transaction-service -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/notification-service -n swiftpay-dev --timeout=240s
kubectl rollout status deployment/frontend -n swiftpay-dev --timeout=240s

echo "[swiftpay-k8s] Verifying live path"
"${ROOT_DIR}/scripts/k8s-dev-verify.sh" --hostname "${HOSTNAME_OVERRIDE}"
