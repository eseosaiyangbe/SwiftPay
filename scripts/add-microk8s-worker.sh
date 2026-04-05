#!/usr/bin/env bash
# add-microk8s-worker.sh
#
# Creates a new Multipass VM and joins it to the existing MicroK8s cluster as
# a worker node. Use this when pods are stuck in Pending due to "Insufficient
# cpu" or "Insufficient memory" and you want more capacity without changing
# replica counts.
#
# Usage:
#   ./scripts/add-microk8s-worker.sh [VM_NAME] [CPUS] [MEMORY_GB] [DISK_GB]
#
# Defaults:
#   VM_NAME    = payflow-worker-3
#   CPUS       = 2
#   MEMORY_GB  = 4
#   DISK_GB    = 20
#
# Requirements:
#   - Multipass installed (macOS: brew install multipass)
#   - microk8s-vm running and healthy (kubectl get nodes shows Ready)

set -euo pipefail

VM_NAME="${1:-payflow-worker-3}"
CPUS="${2:-2}"
MEMORY_GB="${3:-4}"
DISK_GB="${4:-20}"

CONTROL_PLANE="microk8s-vm"

echo "=== Adding worker node: ${VM_NAME} (${CPUS} CPU, ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk) ==="

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v multipass >/dev/null 2>&1; then
  echo "ERROR: multipass not found. Install with: brew install multipass"
  exit 1
fi

if ! multipass list 2>/dev/null | grep -q "${CONTROL_PLANE}.*Running"; then
  echo "ERROR: ${CONTROL_PLANE} is not running. Start it first:"
  echo "  multipass start ${CONTROL_PLANE}"
  exit 1
fi

if multipass list 2>/dev/null | grep -q "^${VM_NAME}"; then
  echo "ERROR: VM '${VM_NAME}' already exists. Choose a different name or delete it first:"
  echo "  multipass delete ${VM_NAME} && multipass purge"
  exit 1
fi

# ── Get join token from control plane ────────────────────────────────────────
echo ""
echo "Generating join token from control plane..."
JOIN_CMD=$(multipass exec "${CONTROL_PLANE}" -- sudo microk8s add-node --format short 2>/dev/null | head -1)

if [ -z "$JOIN_CMD" ]; then
  echo "ERROR: Could not get join token from ${CONTROL_PLANE}."
  echo "Check that microk8s is healthy: multipass exec ${CONTROL_PLANE} -- sudo microk8s status"
  exit 1
fi

echo "Join command obtained."

# ── Create and configure the new VM ──────────────────────────────────────────
echo ""
echo "Creating VM ${VM_NAME} ..."
multipass launch --name "${VM_NAME}" \
  --cpus "${CPUS}" \
  --memory "${MEMORY_GB}G" \
  --disk "${DISK_GB}G" \
  22.04

echo "Installing MicroK8s on ${VM_NAME} ..."
multipass exec "${VM_NAME}" -- bash -c "
  sudo snap install microk8s --classic --channel=1.32/stable
  sudo usermod -aG microk8s ubuntu
  sudo microk8s status --wait-ready
"

# ── Join the cluster ──────────────────────────────────────────────────────────
echo ""
echo "Joining ${VM_NAME} to the cluster ..."
multipass exec "${VM_NAME}" -- sudo ${JOIN_CMD} --worker

# ── Wait for node to become Ready ────────────────────────────────────────────
echo ""
echo "Waiting for ${VM_NAME} to become Ready (up to 90s)..."
for i in $(seq 1 18); do
  STATUS=$(multipass exec "${CONTROL_PLANE}" -- sudo microk8s kubectl get node "${VM_NAME}" \
    --no-headers 2>/dev/null | awk '{print $2}' || true)
  if [ "$STATUS" = "Ready" ]; then
    echo "${VM_NAME} is Ready."
    break
  fi
  echo "  [${i}/18] Status: ${STATUS:-unknown} — waiting 5s ..."
  sleep 5
done

echo ""
echo "=== Cluster nodes ==="
multipass exec "${CONTROL_PLANE}" -- sudo microk8s kubectl get nodes -o wide
echo ""
echo "Done. Pods that were Pending due to resource pressure should now schedule."
echo "Check with: kubectl get pods -n payflow"
