#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_IMAGES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s-start.sh [options] [-- <extra deploy args>]

Start the SwiftPay dev overlay in the current Kubernetes context.

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

cmd=("${ROOT_DIR}/scripts/k8s-dev-deploy.sh")
if [[ "${BUILD_IMAGES}" -eq 0 ]]; then
  cmd+=(--skip-build)
fi
cmd+=("${extra_args[@]}")

exec "${cmd[@]}"
