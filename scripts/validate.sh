#!/usr/bin/env bash
# =============================================================================
# SwiftPay Validation Script — Golden Path Smoke Test
# =============================================================================
# Validates that a running SwiftPay deployment is fully operational end-to-end.
# Run this after starting any environment to confirm everything works.
#
# Usage:
#   ./scripts/validate.sh                        # Docker Compose (default, gateway on localhost:3007)
#   ./scripts/validate.sh --env k8s              # MicroK8s (www.swiftpay.local)
#   ./scripts/validate.sh --env k8s --host api.swiftpay.local
#   ./scripts/validate.sh --env cloud --host https://api.yourdomain.com
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
# =============================================================================
set -euo pipefail

# ---- Parse arguments ----
ENV="docker"
BASE_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)    ENV="$2"; shift 2 ;;
    --host)   BASE_URL="$2"; shift 2 ;;
    *)        echo "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$ENV" in
  docker) BASE_URL="${BASE_URL:-http://localhost:3007}" ;;
  k8s)    BASE_URL="${BASE_URL:-http://api.swiftpay.local}" ;;
  cloud)  : ;; # user must provide --host
esac

PASS=0
FAIL=0

# ---- Helpers ----
green() { printf '\033[0;32m✔ %s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m✘ %s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m  %s\033[0m\n' "$*"; }

check() {
  local label="$1"
  local expected_status="$2"
  local url="$3"
  shift 3
  local http_code
  http_code=$(curl -s -o /tmp/pf_resp -w "%{http_code}" --max-time 5 "$@" "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "$expected_status" ]]; then
    green "$label (HTTP $http_code)"
    ((PASS++)) || true
    return 0
  else
    red "$label — expected HTTP $expected_status, got $http_code"
    info "Response: $(cat /tmp/pf_resp 2>/dev/null | head -c 200)"
    ((FAIL++)) || true
    return 1
  fi
}

check_contains() {
  local label="$1"
  local url="$2"
  local needle="$3"
  shift 3
  local body
  body=$(curl -s --max-time 5 "$@" "$url" 2>/dev/null || echo "")
  if echo "$body" | grep -q "$needle"; then
    green "$label"
    ((PASS++)) || true
  else
    red "$label — expected to find '$needle' in response"
    info "Response: $(echo "$body" | head -c 200)"
    ((FAIL++)) || true
  fi
}

# ---- Run checks ----
echo ""
echo "SwiftPay Validation — environment: $ENV"
echo "Base URL: $BASE_URL"
echo "─────────────────────────────────────────"

echo ""
echo "[ Infrastructure health ]"
check      "API Gateway /health"       200 "$BASE_URL/health"
check_contains "API Gateway reports healthy" "$BASE_URL/health" '"healthy"'

echo ""
echo "[ Auth flow ]"
TEST_EMAIL="validate-$(date +%s)@swiftpay.test"
TEST_PASS="Validate1!"

REGISTER_BODY=$(curl -s --max-time 10 -X POST "$BASE_URL/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\",\"name\":\"Validate User\"}" \
  2>/dev/null || echo "")
ACCESS_TOKEN=$(echo "$REGISTER_BODY" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)

if [[ -n "$ACCESS_TOKEN" ]]; then
  green "Registration (got accessToken)"
  ((PASS++)) || true
else
  red "Registration failed"
  info "Response: $(echo "$REGISTER_BODY" | head -c 300)"
  ((FAIL++)) || true
fi

if [[ -n "$ACCESS_TOKEN" ]]; then
  AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"

  echo ""
  echo "[ Wallet ]"
  USER_ID=$(echo "$REGISTER_BODY" | grep -o '"userId":"[^"]*"' | cut -d'"' -f4)
  if [[ -n "$USER_ID" ]]; then
    check "GET /api/wallets/:userId" 200 "$BASE_URL/api/wallets/$USER_ID" -H "$AUTH_HEADER"
  else
    red "Could not extract userId from register response"
    ((FAIL++)) || true
  fi

  echo ""
  echo "[ Transactions ]"
  check "GET /api/transactions" 200 "$BASE_URL/api/transactions" -H "$AUTH_HEADER"

  echo ""
  echo "[ Notifications ]"
  if [[ -n "$USER_ID" ]]; then
    check "GET /api/notifications/:userId" 200 "$BASE_URL/api/notifications/$USER_ID" -H "$AUTH_HEADER"
  fi
fi

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
  red "Validation FAILED — check logs above"
  echo ""
  echo "Debug commands:"
  if [[ "$ENV" == "docker" ]]; then
    echo "  docker compose logs api-gateway"
    echo "  docker compose logs auth-service"
    echo "  docker compose ps"
  else
    echo "  kubectl logs -n swiftpay deploy/api-gateway"
    echo "  kubectl logs -n swiftpay deploy/auth-service"
    echo "  kubectl get pods -n swiftpay"
  fi
  exit 1
else
  green "All checks passed — SwiftPay is healthy"
  exit 0
fi
