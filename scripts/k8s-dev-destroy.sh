#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-dev-destroy.sh

Delete the SwiftPay k3s dev namespace and wait for removal.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

echo "[swiftpay-k8s] Deleting namespace swiftpay-dev"
kubectl delete namespace swiftpay-dev --ignore-not-found
kubectl wait --for=delete namespace/swiftpay-dev --timeout=240s >/dev/null 2>&1 || true
echo "[swiftpay-k8s] Namespace removal requested"
