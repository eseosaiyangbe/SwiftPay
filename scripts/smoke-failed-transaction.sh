#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
AMOUNT="${SMOKE_FAILED_AMOUNT:-1500.00}"
STAMP="$(date +%Y%m%d%H%M%S)"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

wait_for_transaction() {
  local token="$1"
  local transaction_id="$2"
  local output="$3"
  local status="PENDING"

  for _ in $(seq 1 20); do
    curl -fsS "$BASE_URL/transactions/$transaction_id" \
      -H "Authorization: Bearer $token" > "$output"

    status="$(jq -r '.status' "$output")"
    if [[ "$status" == "COMPLETED" || "$status" == "FAILED" ]]; then
      echo "$status"
      return
    fi

    sleep 1
  done

  echo "$status"
}

require_cmd curl
require_cmd jq

sender_json="$(mktemp)"
receiver_json="$(mktemp)"
tx_json="$(mktemp)"
tx_status_json="$(mktemp)"
sender_wallet_before="$(mktemp)"
receiver_wallet_before="$(mktemp)"
sender_wallet_after="$(mktemp)"
receiver_wallet_after="$(mktemp)"
sender_notifications="$(mktemp)"

cleanup() {
  rm -f \
    "$sender_json" \
    "$receiver_json" \
    "$tx_json" \
    "$tx_status_json" \
    "$sender_wallet_before" \
    "$receiver_wallet_before" \
    "$sender_wallet_after" \
    "$receiver_wallet_after" \
    "$sender_notifications"
}
trap cleanup EXIT

sender_email="failed.sender.${STAMP}@swiftpay.local"
receiver_email="failed.receiver.${STAMP}@swiftpay.local"

curl -fsS -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$sender_email\",\"password\":\"$PASSWORD\",\"name\":\"Failed Sender $STAMP\"}" > "$sender_json"

curl -fsS -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$receiver_email\",\"password\":\"$PASSWORD\",\"name\":\"Failed Receiver $STAMP\"}" > "$receiver_json"

sender_id="$(jq -r '.user.id' "$sender_json")"
receiver_id="$(jq -r '.user.id' "$receiver_json")"
sender_token="$(jq -r '.accessToken' "$sender_json")"
receiver_token="$(jq -r '.accessToken' "$receiver_json")"

curl -fsS "$BASE_URL/wallets/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_wallet_before"

curl -fsS "$BASE_URL/wallets/$receiver_id" \
  -H "Authorization: Bearer $receiver_token" > "$receiver_wallet_before"

curl -fsS -X POST "$BASE_URL/transactions" \
  -H "Authorization: Bearer $sender_token" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: failed-${STAMP}" \
  -d "{\"fromUserId\":\"$sender_id\",\"toUserId\":\"$receiver_id\",\"amount\":$AMOUNT}" > "$tx_json"

transaction_id="$(jq -r '.id' "$tx_json")"
status="$(wait_for_transaction "$sender_token" "$transaction_id" "$tx_status_json")"

curl -fsS "$BASE_URL/wallets/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_wallet_after"

curl -fsS "$BASE_URL/wallets/$receiver_id" \
  -H "Authorization: Bearer $receiver_token" > "$receiver_wallet_after"

curl -fsS "$BASE_URL/notifications/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_notifications"

sender_failed_notifications="$(
  jq --arg tx "$transaction_id" \
    '[.[] | select(.transaction_id == $tx and .type == "TRANSACTION_FAILED")] | length' \
    "$sender_notifications"
)"
error_message="$(jq -r '.error_message // empty' "$tx_status_json")"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg senderEmail "$sender_email" \
  --arg receiverEmail "$receiver_email" \
  --arg senderId "$sender_id" \
  --arg receiverId "$receiver_id" \
  --arg transactionId "$transaction_id" \
  --arg status "$status" \
  --arg amount "$AMOUNT" \
  --arg error "$error_message" \
  --arg senderBefore "$(jq -r '.balance' "$sender_wallet_before")" \
  --arg senderAfter "$(jq -r '.balance' "$sender_wallet_after")" \
  --arg receiverBefore "$(jq -r '.balance' "$receiver_wallet_before")" \
  --arg receiverAfter "$(jq -r '.balance' "$receiver_wallet_after")" \
  --argjson senderFailed "$sender_failed_notifications" \
  '{
    baseUrl: $baseUrl,
    senderEmail: $senderEmail,
    receiverEmail: $receiverEmail,
    senderId: $senderId,
    receiverId: $receiverId,
    transactionId: $transactionId,
    status: $status,
    amount: $amount,
    error: $error,
    balances: {
      senderBefore: $senderBefore,
      senderAfter: $senderAfter,
      receiverBefore: $receiverBefore,
      receiverAfter: $receiverAfter
    },
    notifications: {
      senderFailed: $senderFailed
    }
  }'

if [[ "$status" != "FAILED" ]]; then
  echo "Expected transaction to fail, got: $status" >&2
  exit 1
fi

if [[ "$error_message" != "Insufficient funds" ]]; then
  echo "Expected error_message to be 'Insufficient funds', got: $error_message" >&2
  exit 1
fi

if [[ "$sender_failed_notifications" -lt 1 ]]; then
  echo "Expected sender failure notification for transaction: $transaction_id" >&2
  exit 1
fi

echo "Failed transaction smoke test passed."
