#!/usr/bin/env bash
# fix-microk8s-nodes.sh
#
# Starts any stopped Multipass VMs that are part of the SwiftPay MicroK8s
# cluster and waits for their nodes to become Ready. Run this after a Mac
# restart or after manually stopping the VMs.
#
# Usage:
#   ./scripts/fix-microk8s-nodes.sh
#
# What it does:
#   1. Lists all Multipass VMs.
#   2. Starts any that are Stopped/Suspended.
#   3. Waits for each node to appear Ready in kubectl.
#
# After this, all pods that were Pending/Unknown should reschedule.

set -euo pipefail

CONTROL_PLANE="microk8s-vm"

if ! command -v multipass >/dev/null 2>&1; then
  echo "ERROR: multipass not found. Install with: brew install multipass"
  exit 1
fi

# ── Start stopped VMs ─────────────────────────────────────────────────────────
echo "=== Checking Multipass VM states ==="
multipass list

STOPPED_VMS=$(multipass list --format csv 2>/dev/null \
  | awk -F',' 'NR>1 && $2 ~ /Stopped|Suspended/ {print $1}' \
  | tr -d ' ')

if [ -z "$STOPPED_VMS" ]; then
  echo ""
  echo "All VMs are already running."
else
  echo ""
  echo "Starting stopped VMs: $(echo $STOPPED_VMS | tr '\n' ' ')"
  for VM in $STOPPED_VMS; do
    echo "  Starting ${VM} ..."
    multipass start "$VM"
  done
fi

# ── Wait for control plane ────────────────────────────────────────────────────
echo ""
echo "Waiting for MicroK8s control plane to be ready ..."
multipass exec "${CONTROL_PLANE}" -- sudo microk8s status --wait-ready --timeout 120 \
  || { echo "WARNING: control plane did not become ready within 120s — check: multipass exec microk8s-vm -- sudo microk8s status"; }

# ── Wait for all nodes Ready ──────────────────────────────────────────────────
echo ""
echo "Waiting for all nodes to become Ready (up to 120s) ..."
for i in $(seq 1 24); do
  NOT_READY=$(multipass exec "${CONTROL_PLANE}" -- sudo microk8s kubectl get nodes \
    --no-headers 2>/dev/null | grep -v " Ready" | grep -v "NAME" || true)
  if [ -z "$NOT_READY" ]; then
    echo "All nodes are Ready."
    break
  fi
  echo "  [${i}/24] Not-ready nodes:"
  echo "$NOT_READY" | sed 's/^/    /'
  sleep 5
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Node status ==="
multipass exec "${CONTROL_PLANE}" -- sudo microk8s kubectl get nodes -o wide

echo ""
echo "=== Pod status ==="
multipass exec "${CONTROL_PLANE}" -- sudo microk8s kubectl get pods -n swiftpay

echo ""
echo "If pods are still Pending, check events:"
echo "  kubectl get events -n swiftpay --sort-by='.lastTimestamp' | tail -20"
