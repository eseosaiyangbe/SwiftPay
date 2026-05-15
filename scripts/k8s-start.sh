#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_IMAGES=0
NAMESPACE="swiftpay-dev"

DEPLOYMENTS=(
  api-gateway
  auth-service
  frontend
  notification-service
  rabbitmq
  redis
  transaction-service
  wallet-service
)

STATEFULSETS=(
  postgres
)

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-start.sh [options] [-- <extra deploy args>]

Start the SwiftPay dev overlay in the current Kubernetes context.

If the SwiftPay namespace already exists, this script resumes the preserved
workloads by scaling them back up. If the namespace does not exist yet, it
falls back to the full deploy path.

By default, this reuses existing local images. Use --build when you
intentionally want fresh local image builds.

Options:
  --build      Rebuild images before deploy
  -h, --help   Show this help message
EOF
}

extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_IMAGES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      extra_args+=("$@")
      break
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
  esac
done

has_existing_namespace=0
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  has_existing_namespace=1
fi

if [[ "${BUILD_IMAGES}" -eq 0 && "${has_existing_namespace}" -eq 1 ]]; then
  echo "[swiftpay-k8s] Existing namespace detected. Resuming preserved workloads."
  kubectl -n "${NAMESPACE}" scale statefulset "${STATEFULSETS[@]}" --replicas=1
  kubectl -n "${NAMESPACE}" scale deployment "${DEPLOYMENTS[@]}" --replicas=1

  echo "[swiftpay-k8s] Waiting for infrastructure"
  kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/redis -n "${NAMESPACE}" --timeout=180s
  kubectl rollout status deployment/rabbitmq -n "${NAMESPACE}" --timeout=180s

  echo "[swiftpay-k8s] Waiting for services"
  kubectl rollout status deployment/api-gateway -n "${NAMESPACE}" --timeout=240s
  kubectl rollout status deployment/auth-service -n "${NAMESPACE}" --timeout=240s
  kubectl rollout status deployment/wallet-service -n "${NAMESPACE}" --timeout=240s
  kubectl rollout status deployment/transaction-service -n "${NAMESPACE}" --timeout=240s
  kubectl rollout status deployment/notification-service -n "${NAMESPACE}" --timeout=240s
  kubectl rollout status deployment/frontend -n "${NAMESPACE}" --timeout=240s

  exit 0
fi

cmd=("${ROOT_DIR}/scripts/k8s-dev-deploy.sh")
if [[ "${BUILD_IMAGES}" -eq 0 ]]; then
  cmd+=(--skip-build)
fi
if [[ "${#extra_args[@]}" -gt 0 ]]; then
  cmd+=("${extra_args[@]}")
fi

exec "${cmd[@]}"
