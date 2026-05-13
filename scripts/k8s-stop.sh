#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-stop.sh

Stop the SwiftPay dev overlay from the current Kubernetes context.
This removes the overlay resources but does not intentionally purge persistent
volume data.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

exec kubectl delete --ignore-not-found -k "${ROOT_DIR}/k8s/overlays/dev"
