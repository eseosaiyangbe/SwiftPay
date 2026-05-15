#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="swiftpay-dev"

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-stop.sh [options]

Stop the SwiftPay dev overlay from the current Kubernetes context.
This preserves the namespace and persistent data by scaling SwiftPay workloads
down to zero instead of deleting the full overlay.

Options:
  --wait       Wait for workloads to terminate before returning
  -h, --help   Show this help message
EOF
}

WAIT_FOR_DELETE=0

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_FOR_DELETE=1
      shift
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

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "[swiftpay-k8s] Namespace ${NAMESPACE} does not exist. Nothing to stop."
  exit 0
fi

echo "[swiftpay-k8s] Scaling deployments to zero"
kubectl -n "${NAMESPACE}" scale deployment "${DEPLOYMENTS[@]}" --replicas=0 >/dev/null 2>&1 || true

echo "[swiftpay-k8s] Scaling statefulsets to zero"
kubectl -n "${NAMESPACE}" scale statefulset "${STATEFULSETS[@]}" --replicas=0 >/dev/null 2>&1 || true

if [[ "${WAIT_FOR_DELETE}" -eq 1 ]]; then
  echo "[swiftpay-k8s] Waiting for workload shutdown"
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=api-gateway --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=auth-service --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=frontend --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=notification-service --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=rabbitmq --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=redis --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=transaction-service --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=wallet-service --timeout=300s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" wait --for=delete pod -l app=postgres --timeout=300s >/dev/null 2>&1 || true
fi

echo "[swiftpay-k8s] SwiftPay workloads stopped. Namespace and persistent data were preserved."
