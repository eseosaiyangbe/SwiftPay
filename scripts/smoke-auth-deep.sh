#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
NEW_PASSWORD="${SMOKE_NEW_PASSWORD:-SwiftPay456}"
WRONG_PASSWORD="${SMOKE_WRONG_PASSWORD:-WrongSwiftPay123}"
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

lock_register_json="$(mktemp)"
lock_attempt_json="$(mktemp)"
lock_good_password_json="$(mktemp)"
password_register_json="$(mktemp)"
password_change_json="$(mktemp)"
old_token_me_json="$(mktemp)"
old_refresh_json="$(mktemp)"
old_password_login_json="$(mktemp)"
new_password_login_json="$(mktemp)"

cleanup() {
  rm -f \
    "$lock_register_json" \
    "$lock_attempt_json" \
    "$lock_good_password_json" \
    "$password_register_json" \
    "$password_change_json" \
    "$old_token_me_json" \
    "$old_refresh_json" \
    "$old_password_login_json" \
    "$new_password_login_json"
}
trap cleanup EXIT

lock_email="lockout.${STAMP}@swiftpay.local"
password_email="password.${STAMP}@swiftpay.local"

request POST "$BASE_URL/auth/register" "$lock_register_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$lock_email\",\"password\":\"$PASSWORD\",\"name\":\"Lockout Smoke $STAMP\"}"

last_failed_status=""
for attempt in $(seq 1 5); do
  last_failed_status="$(
    request_status POST "$BASE_URL/auth/login" "$lock_attempt_json" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$lock_email\",\"password\":\"$WRONG_PASSWORD\"}"
  )"

  if [[ "$attempt" -lt 5 && "$last_failed_status" != "401" ]]; then
    echo "Expected failed login attempt $attempt to return 401, got: $last_failed_status" >&2
    cat "$lock_attempt_json" >&2
    exit 1
  fi
done

locked_good_password_status="$(
  request_status POST "$BASE_URL/auth/login" "$lock_good_password_json" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$lock_email\",\"password\":\"$PASSWORD\"}"
)"

request POST "$BASE_URL/auth/register" "$password_register_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$password_email\",\"password\":\"$PASSWORD\",\"name\":\"Password Smoke $STAMP\"}"

password_user_id="$(jq -r '.user.id' "$password_register_json")"
old_access_token="$(jq -r '.accessToken' "$password_register_json")"
old_refresh_token="$(jq -r '.refreshToken' "$password_register_json")"

request POST "$BASE_URL/auth/change-password" "$password_change_json" \
  -H "Authorization: Bearer $old_access_token" \
  -H "Content-Type: application/json" \
  -d "{\"currentPassword\":\"$PASSWORD\",\"newPassword\":\"$NEW_PASSWORD\"}"

old_access_status="$(
  request_status GET "$BASE_URL/auth/me" "$old_token_me_json" \
    -H "Authorization: Bearer $old_access_token"
)"

old_refresh_status="$(
  request_status POST "$BASE_URL/auth/refresh" "$old_refresh_json" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"$old_refresh_token\"}"
)"

old_password_status="$(
  request_status POST "$BASE_URL/auth/login" "$old_password_login_json" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$password_email\",\"password\":\"$PASSWORD\"}"
)"

new_password_status="$(
  request_status POST "$BASE_URL/auth/login" "$new_password_login_json" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$password_email\",\"password\":\"$NEW_PASSWORD\"}"
)"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg lockEmail "$lock_email" \
  --arg passwordEmail "$password_email" \
  --arg passwordUserId "$password_user_id" \
  --arg lastFailedStatus "$last_failed_status" \
  --arg lockedGoodPasswordStatus "$locked_good_password_status" \
  --arg passwordChangeMessage "$(jq -r '.message // empty' "$password_change_json")" \
  --arg oldAccessStatus "$old_access_status" \
  --arg oldRefreshStatus "$old_refresh_status" \
  --arg oldPasswordStatus "$old_password_status" \
  --arg newPasswordStatus "$new_password_status" \
  '{
    baseUrl: $baseUrl,
    accountLockout: {
      email: $lockEmail,
      fifthBadPasswordStatus: $lastFailedStatus,
      correctPasswordWhileLockedStatus: $lockedGoodPasswordStatus
    },
    passwordChange: {
      email: $passwordEmail,
      userId: $passwordUserId,
      message: $passwordChangeMessage,
      oldAccessTokenStatus: $oldAccessStatus,
      oldRefreshTokenStatus: $oldRefreshStatus,
      oldPasswordLoginStatus: $oldPasswordStatus,
      newPasswordLoginStatus: $newPasswordStatus
    }
  }'

if [[ "$last_failed_status" != "401" ]]; then
  echo "Expected fifth bad password attempt to return 401, got: $last_failed_status" >&2
  cat "$lock_attempt_json" >&2
  exit 1
fi

if [[ "$locked_good_password_status" != "423" ]]; then
  echo "Expected correct password to be rejected while account is locked with 423, got: $locked_good_password_status" >&2
  cat "$lock_good_password_json" >&2
  exit 1
fi

if [[ "$(jq -r '.message // empty' "$password_change_json")" != "Password changed successfully" ]]; then
  echo "Expected password change to succeed" >&2
  cat "$password_change_json" >&2
  exit 1
fi

if [[ "$old_access_status" != "401" ]]; then
  echo "Expected old access token to be rejected after password change with 401, got: $old_access_status" >&2
  cat "$old_token_me_json" >&2
  exit 1
fi

if [[ "$old_refresh_status" != "401" ]]; then
  echo "Expected old refresh token to be rejected after password change with 401, got: $old_refresh_status" >&2
  cat "$old_refresh_json" >&2
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

echo "Deep auth security smoke test passed."
