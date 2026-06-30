#!/usr/bin/env bash
set -euo pipefail

URL="${URL:-https://swiftpay.eseosadevbox.com}"

echo "[smoke-dev] verifying ArgoCD application status"
kubectl get application swiftpay-dev -n argocd -o wide

echo
echo "[smoke-dev] verifying dev namespace workload state"
kubectl get pods -n swiftpay-dev

echo
echo "[smoke-dev] probing public root"
curl -fsSIL "$URL"

echo
echo "[smoke-dev] probing public API health"
curl -fsS "$URL/api/health"

echo
echo "[smoke-dev] public dev edge is reachable"
