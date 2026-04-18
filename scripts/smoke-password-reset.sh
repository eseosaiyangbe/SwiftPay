#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
NEW_PASSWORD="${SMOKE_RESET_PASSWORD:-SwiftPay789}"
STAMP="$(date +%Y%m%d%H%M%S).$$"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

request() {
  local method="$1"
  local url="$2"
  local output="$3"
  shift 3

  curl -fsS -X "$method" "$url" "$@" > "$output"
}

request_status() {
  local method="$1"
  local url="$2"
  local output="$3"
  shift 3

  curl -sS -o "$output" -w "%{http_code}" -X "$method" "$url" "$@"
}

require_cmd curl
require_cmd jq

register_json="$(mktemp)"
forgot_json="$(mktemp)"
reset_json="$(mktemp)"
old_password_login_json="$(mktemp)"
new_password_login_json="$(mktemp)"
reused_token_json="$(mktemp)"

cleanup() {
  rm -f \
    "$register_json" \
    "$forgot_json" \
    "$reset_json" \
    "$old_password_login_json" \
    "$new_password_login_json" \
    "$reused_token_json"
}
trap cleanup EXIT

email="reset.${STAMP}@swiftpay.local"

request POST "$BASE_URL/auth/register" "$register_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"Reset Smoke $STAMP\"}"

user_id="$(jq -r '.user.id' "$register_json")"

request POST "$BASE_URL/auth/forgot-password" "$forgot_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$email\"}"

reset_token="$(jq -r '.resetToken // empty' "$forgot_json")"
if [[ -z "$reset_token" ]]; then
  echo "Expected resetToken in non-production forgot-password response" >&2
  cat "$forgot_json" >&2
  exit 1
fi

request POST "$BASE_URL/auth/reset-password" "$reset_json" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$reset_token\",\"newPassword\":\"$NEW_PASSWORD\"}"

old_password_status="$(
  request_status POST "$BASE_URL/auth/login" "$old_password_login_json" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
)"

new_password_status="$(
  request_status POST "$BASE_URL/auth/login" "$new_password_login_json" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$NEW_PASSWORD\"}"
)"

reused_token_status="$(
  request_status POST "$BASE_URL/auth/reset-password" "$reused_token_json" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$reset_token\",\"newPassword\":\"$PASSWORD\"}"
)"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg email "$email" \
  --arg userId "$user_id" \
  --arg forgotMessage "$(jq -r '.message // empty' "$forgot_json")" \
  --arg resetMessage "$(jq -r '.message // empty' "$reset_json")" \
  --arg oldPasswordStatus "$old_password_status" \
  --arg newPasswordStatus "$new_password_status" \
  --arg reusedTokenStatus "$reused_token_status" \
  '{
    baseUrl: $baseUrl,
    email: $email,
    userId: $userId,
    forgotPassword: {
      message: $forgotMessage
    },
    resetPassword: {
      message: $resetMessage,
      oldPasswordLoginStatus: $oldPasswordStatus,
      newPasswordLoginStatus: $newPasswordStatus,
      reusedTokenStatus: $reusedTokenStatus
    }
  }'

if [[ "$(jq -r '.message // empty' "$reset_json")" != "Password reset successfully. Please sign in." ]]; then
  echo "Expected password reset to succeed" >&2
  cat "$reset_json" >&2
  exit 1
fi

if [[ "$old_password_status" != "401" ]]; then
  echo "Expected old password login to fail with 401, got: $old_password_status" >&2
  cat "$old_password_login_json" >&2
  exit 1
fi

if [[ "$new_password_status" != "200" ]]; then
  echo "Expected new password login to succeed with 200, got: $new_password_status" >&2
  cat "$new_password_login_json" >&2
  exit 1
fi

if [[ "$reused_token_status" != "400" ]]; then
  echo "Expected reused reset token to fail with 400, got: $reused_token_status" >&2
  cat "$reused_token_json" >&2
  exit 1
fi

echo "Password reset smoke test passed."
