#!/bin/bash

# ============================================
# Generate Self-Signed TLS Certificate for Local Development
# ============================================
# Purpose: Creates a self-signed certificate for HTTPS testing
# Why: Mimics production HTTPS flow without needing a real domain
# 
# What this does:
#   1. Creates a private key (tls.key)
#   2. Creates a certificate (tls.crt) valid for 365 days
#   3. Includes both www.swiftpay.local and api.swiftpay.local
#
# Note: Browsers will show a security warning (this is normal for self-signed certs)
# In production, you'd use Let's Encrypt (real certificates, no warnings)

set -e

echo "🔐 Generating self-signed TLS certificate for SwiftPay..."
echo ""

# Create certificate directory
CERT_DIR="$(dirname "$0")/certs"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# Generate private key and certificate
# -x509: Create self-signed certificate (not a certificate request)
# -nodes: Don't encrypt the private key (no password needed)
# -days 365: Certificate valid for 1 year
# -newkey rsa:2048: Create new RSA key with 2048 bits
# -keyout: Output file for private key
# -out: Output file for certificate
# -subj: Subject information (CN = Common Name)
# -addext: Add extension (Subject Alternative Name for multiple domains)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=swiftpay.local" \
  -addext "subjectAltName=DNS:www.swiftpay.local,DNS:api.swiftpay.local"

echo "Certificate generated successfully"
echo ""
echo "Files created:"
echo "  - $CERT_DIR/tls.key (private key - keep this secret!)"
echo "  - $CERT_DIR/tls.crt (certificate)"
echo ""
echo "📋 Next steps:"
echo "  1. Create Kubernetes secret:"
echo "     kubectl create secret tls swiftpay-local-tls \\"
echo "       --cert=$CERT_DIR/tls.crt \\"
echo "       --key=$CERT_DIR/tls.key \\"
echo "       -n swiftpay"
echo ""
echo "  2. Deploy TLS ingress:"
echo "     kubectl apply -f k8s/ingress/tls-ingress-local.yaml"
echo ""
echo "  3. Add to /etc/hosts (macOS/Linux) or C:\\Windows\\System32\\drivers\\etc\\hosts (Windows):"
echo "     <ingress-ip> www.swiftpay.local api.swiftpay.local"
echo ""
echo "  4. Access:"
echo "     - Frontend: https://www.swiftpay.local"
echo "     - API: https://api.swiftpay.local"
echo ""
echo "Note: Browsers will show a security warning. Click Advanced then Proceed to continue."
echo "   This is normal for self-signed certificates. In production, you'd use Let's Encrypt."

