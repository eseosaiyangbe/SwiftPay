#!/usr/bin/env bash
# setup-hosts-payflow-local.sh
#
# Adds (or updates) the payflow.local entries in /etc/hosts so the local
# Ingress works without port-forwarding. Safe to re-run — it replaces the
# old line instead of duplicating it.
#
# Usage:
#   ./scripts/setup-hosts-payflow-local.sh
#
# What it does:
#   1. Detects the MicroK8s VM IP (Multipass on macOS, or localhost on Linux).
#   2. Removes any existing payflow.local lines from /etc/hosts.
#   3. Appends a fresh line with the current IP.
#
# After this, open http://www.payflow.local in your browser.

set -euo pipefail

HOSTS_FILE="/etc/hosts"
HOSTS=(www.payflow.local payflow.local api.payflow.local)

# ── Detect VM IP ──────────────────────────────────────────────────────────────
if command -v multipass >/dev/null 2>&1; then
  VM_IP=$(multipass list --format csv 2>/dev/null \
    | awk -F',' '/microk8s-vm/ && /Running/ {print $3}' \
    | tr -d ' ')
  if [ -z "$VM_IP" ]; then
    echo "ERROR: microk8s-vm not found or not running. Start it with:"
    echo "  multipass start microk8s-vm"
    exit 1
  fi
else
  # Linux — MicroK8s runs directly; ingress is on localhost
  VM_IP="127.0.0.1"
fi

echo "MicroK8s VM IP: $VM_IP"

# ── Update /etc/hosts ─────────────────────────────────────────────────────────
# Build the new line
NEW_LINE="${VM_IP}   ${HOSTS[*]}"

# Check if any payflow.local entry already exists
if grep -q "payflow\.local" "$HOSTS_FILE" 2>/dev/null; then
  echo "Updating existing payflow.local entry in $HOSTS_FILE ..."
  # Remove old lines (requires sudo)
  sudo sed -i '' '/payflow\.local/d' "$HOSTS_FILE" 2>/dev/null \
    || sudo sed -i '/payflow\.local/d' "$HOSTS_FILE"
else
  echo "Adding payflow.local entries to $HOSTS_FILE ..."
fi

echo "$NEW_LINE" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "Done. Current payflow entries:"
grep "payflow" "$HOSTS_FILE"
echo ""
echo "Open http://www.payflow.local in your browser."
