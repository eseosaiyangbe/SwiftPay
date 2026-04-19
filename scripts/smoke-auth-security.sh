#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
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
refresh_json="$(mktemp)"
old_refresh_replay_json="$(mktemp)"
logout_json="$(mktemp)"
logged_out_me_json="$(mktemp)"

cleanup() {
  rm -f \
    "$register_json" \
    "$refresh_json" \
    "$old_refresh_replay_json" \
    "$logout_json" \
    "$logged_out_me_json"
}
trap cleanup EXIT

email="security.${STAMP}@swiftpay.local"

request POST "$BASE_URL/auth/register" "$register_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"Security Smoke $STAMP\"}"

user_id="$(jq -r '.user.id' "$register_json")"
access_token="$(jq -r '.accessToken' "$register_json")"
refresh_token="$(jq -r '.refreshToken' "$register_json")"

request POST "$BASE_URL/auth/refresh" "$refresh_json" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$refresh_token\"}"

rotated_access_token="$(jq -r '.accessToken' "$refresh_json")"
rotated_refresh_token="$(jq -r '.refreshToken' "$refresh_json")"

old_refresh_status="$(
  request_status POST "$BASE_URL/auth/refresh" "$old_refresh_replay_json" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"$refresh_token\"}"
)"

request POST "$BASE_URL/auth/logout" "$logout_json" \
  -H "Authorization: Bearer $rotated_access_token" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$rotated_refresh_token\"}"

logged_out_status="$(
  request_status GET "$BASE_URL/auth/me" "$logged_out_me_json" \
    -H "Authorization: Bearer $rotated_access_token"
)"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg email "$email" \
  --arg userId "$user_id" \
  --arg oldRefreshStatus "$old_refresh_status" \
  --arg loggedOutStatus "$logged_out_status" \
  --arg logoutMessage "$(jq -r '.message // empty' "$logout_json")" \
  '{
    baseUrl: $baseUrl,
    email: $email,
    userId: $userId,
    refreshRotation: {
      oldRefreshReplayStatus: $oldRefreshStatus
    },
    logout: {
      message: $logoutMessage,
      loggedOutAccessTokenStatus: $loggedOutStatus
    }
  }'

if [[ "$rotated_refresh_token" == "$refresh_token" ]]; then
  echo "Expected refresh token rotation to issue a different token" >&2
  exit 1
fi

if [[ "$old_refresh_status" != "401" ]]; then
  echo "Expected reused refresh token to be rejected with 401, got: $old_refresh_status" >&2
  cat "$old_refresh_replay_json" >&2
  exit 1
fi

if [[ "$(jq -r '.message // empty' "$logout_json")" != "Logout successful" ]]; then
  echo "Expected logout to succeed" >&2
  cat "$logout_json" >&2
  exit 1
fi

if [[ "$logged_out_status" != "401" ]]; then
  echo "Expected logged-out access token to be rejected with 401, got: $logged_out_status" >&2
  cat "$logged_out_me_json" >&2
  exit 1
fi

echo "Auth security smoke test passed."
