#!/usr/bin/env bash
# setup-hosts-swiftpay-local.sh
#
# Adds (or updates) the swiftpay.local entries in /etc/hosts so the local
# Ingress works without port-forwarding. Safe to re-run — it replaces the
# old line instead of duplicating it.
#
# Usage:
#   ./scripts/setup-hosts-swiftpay-local.sh
#
# What it does:
#   1. Detects the MicroK8s VM IP (Multipass on macOS, or localhost on Linux).
#   2. Removes any existing swiftpay.local lines from /etc/hosts.
#   3. Appends a fresh line with the current IP.
#
# After this, open http://www.swiftpay.local in your browser.

set -euo pipefail

HOSTS_FILE="/etc/hosts"
HOSTS=(www.swiftpay.local swiftpay.local api.swiftpay.local)

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

# Check if any swiftpay.local entry already exists
if grep -q "swiftpay\.local" "$HOSTS_FILE" 2>/dev/null; then
  echo "Updating existing swiftpay.local entry in $HOSTS_FILE ..."
  # Remove old lines (requires sudo)
  sudo sed -i '' '/swiftpay\.local/d' "$HOSTS_FILE" 2>/dev/null \
    || sudo sed -i '/swiftpay\.local/d' "$HOSTS_FILE"
else
  echo "Adding swiftpay.local entries to $HOSTS_FILE ..."
fi

echo "$NEW_LINE" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "Done. Current swiftpay entries:"
grep "swiftpay" "$HOSTS_FILE"
echo ""
echo "Open http://www.swiftpay.local in your browser."
