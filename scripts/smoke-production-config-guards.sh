#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd jq

auth_weak_output="$(mktemp)"
gateway_cors_output="$(mktemp)"
gateway_jwt_output="$(mktemp)"

cleanup() {
  rm -f "$auth_weak_output" "$gateway_cors_output" "$gateway_jwt_output"
}
trap cleanup EXIT

auth_weak_status=0
docker compose run --rm --no-deps \
  -e NODE_ENV=production \
  -e DB_PASSWORD=production-test-password \
  -e JWT_SECRET=change-me \
  auth-service \
  node -e "require('./server')" > "$auth_weak_output" 2>&1 || auth_weak_status=$?

gateway_cors_status=0
docker compose run --rm --no-deps \
  -e NODE_ENV=production \
  -e JWT_SECRET=12345678901234567890123456789012 \
  -e CORS_ORIGIN='*' \
  api-gateway \
  node -e "require('./server')" > "$gateway_cors_output" 2>&1 || gateway_cors_status=$?

gateway_jwt_status=0
docker compose run --rm --no-deps \
  -e NODE_ENV=production \
  -e JWT_SECRET=change-me \
  -e CORS_ORIGIN=https://swiftpay.example.com \
  api-gateway \
  node -e "require('./server')" > "$gateway_jwt_output" 2>&1 || gateway_jwt_status=$?

jq -n \
  --argjson authWeakStatus "$auth_weak_status" \
  --argjson gatewayCorsStatus "$gateway_cors_status" \
  --argjson gatewayJwtStatus "$gateway_jwt_status" \
  '{
    productionGuards: {
      authServiceWeakJwtExitStatus: $authWeakStatus,
      apiGatewayWildcardCorsExitStatus: $gatewayCorsStatus,
      apiGatewayWeakJwtExitStatus: $gatewayJwtStatus
    }
  }'

if [[ "$auth_weak_status" -eq 0 ]]; then
  echo "Expected auth-service to refuse weak JWT_SECRET in production" >&2
  cat "$auth_weak_output" >&2
  exit 1
fi

if ! grep -q "JWT_SECRET must be set to a strong non-default value in production" "$auth_weak_output"; then
  echo "Expected auth-service weak JWT error message" >&2
  cat "$auth_weak_output" >&2
  exit 1
fi

if [[ "$gateway_cors_status" -eq 0 ]]; then
  echo "Expected api-gateway to refuse wildcard CORS_ORIGIN in production" >&2
  cat "$gateway_cors_output" >&2
  exit 1
fi

if ! grep -q "CORS_ORIGIN must list explicit trusted origins in production" "$gateway_cors_output"; then
  echo "Expected api-gateway wildcard CORS error message" >&2
  cat "$gateway_cors_output" >&2
  exit 1
fi

if [[ "$gateway_jwt_status" -eq 0 ]]; then
  echo "Expected api-gateway to refuse weak JWT_SECRET in production" >&2
  cat "$gateway_jwt_output" >&2
  exit 1
fi

if ! grep -q "JWT_SECRET must be set to a strong non-default value in production" "$gateway_jwt_output"; then
  echo "Expected api-gateway weak JWT error message" >&2
  cat "$gateway_jwt_output" >&2
  exit 1
fi

echo "Production config guard smoke test passed."
