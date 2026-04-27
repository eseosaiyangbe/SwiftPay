#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-dev-verify.sh [options]

Run the SwiftPay k3s dev verification path against the current Kubernetes context.

Options:
  --hostname HOST  Override frontend ingress hostname target (default: www.swiftpay.devops.local)
  --api-host HOST  Override API ingress hostname target (default: api.swiftpay.devops.local)
  -h, --help       Show this help message
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTNAME_OVERRIDE="www.swiftpay.devops.local"
API_HOST_OVERRIDE="api.swiftpay.devops.local"
PORT_FORWARD_PID=""

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      HOSTNAME_OVERRIDE="${2:?Missing hostname value}"
      shift 2
      ;;
    --api-host)
      API_HOST_OVERRIDE="${2:?Missing API hostname value}"
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

TRAEFIK_ADDR="$(kubectl get ingress -n swiftpay-dev swiftpay -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
if [[ -z "$TRAEFIK_ADDR" ]]; then
  TRAEFIK_ADDR="$(kubectl get ingress -n swiftpay-dev swiftpay -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
fi

if [[ -z "$TRAEFIK_ADDR" ]]; then
  echo "ERROR: Could not determine SwiftPay ingress address." >&2
  exit 1
fi

echo "[swiftpay-k8s] Traefik address: $TRAEFIK_ADDR"
echo "[swiftpay-k8s] Verifying Kubernetes objects"
kubectl get pods -n swiftpay-dev
kubectl get svc -n swiftpay-dev
kubectl get ingress -n swiftpay-dev

echo "[swiftpay-k8s] Verifying ingress endpoints"
curl -fsS -H "Host: ${HOSTNAME_OVERRIDE}" "http://${TRAEFIK_ADDR}/" >/dev/null
curl -fsS -H "Host: ${API_HOST_OVERRIDE}" "http://${TRAEFIK_ADDR}/health" >/dev/null

echo "[swiftpay-k8s] Running end-to-end API validation via port-forward"
kubectl port-forward -n swiftpay-dev svc/api-gateway 38080:80 >/tmp/swiftpay-k8s-port-forward.log 2>&1 &
PORT_FORWARD_PID="$!"
for _ in {1..20}; do
  if curl -fsS http://127.0.0.1:38080/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
"${ROOT_DIR}/scripts/validate.sh" --env cloud --host http://127.0.0.1:38080

echo "[swiftpay-k8s] Verifying database, Redis, and RabbitMQ"
kubectl exec -n swiftpay-dev statefulset/postgres -- sh -lc 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
kubectl exec -n swiftpay-dev deploy/redis -- sh -lc 'redis-cli ping | grep -q PONG' >/dev/null
kubectl exec -n swiftpay-dev deploy/rabbitmq -- sh -lc 'nc -z 127.0.0.1 5672' >/dev/null

echo "[swiftpay-k8s] Verification passed"
