#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
AMOUNT="${SMOKE_AMOUNT:-25.50}"
STAMP="$(date +%Y%m%d%H%M%S)"

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
receiver_notifications="$(mktemp)"

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
    "$sender_notifications" \
    "$receiver_notifications"
}
trap cleanup EXIT

sender_email="smoke.sender.${STAMP}@swiftpay.local"
receiver_email="smoke.receiver.${STAMP}@swiftpay.local"

request POST "$BASE_URL/auth/register" "$sender_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$sender_email\",\"password\":\"$PASSWORD\",\"name\":\"Smoke Sender $STAMP\"}"

request POST "$BASE_URL/auth/register" "$receiver_json" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$receiver_email\",\"password\":\"$PASSWORD\",\"name\":\"Smoke Receiver $STAMP\"}"

sender_id="$(jq -r '.user.id' "$sender_json")"
receiver_id="$(jq -r '.user.id' "$receiver_json")"
sender_token="$(jq -r '.accessToken' "$sender_json")"
receiver_token="$(jq -r '.accessToken' "$receiver_json")"

curl -fsS "$BASE_URL/wallets/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_wallet_before"

curl -fsS "$BASE_URL/wallets/$receiver_id" \
  -H "Authorization: Bearer $receiver_token" > "$receiver_wallet_before"

request POST "$BASE_URL/transactions" "$tx_json" \
  -H "Authorization: Bearer $sender_token" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-${STAMP}" \
  -d "{\"fromUserId\":\"$sender_id\",\"toUserId\":\"$receiver_id\",\"amount\":$AMOUNT}"

transaction_id="$(jq -r '.id' "$tx_json")"
status="$(wait_for_transaction "$sender_token" "$transaction_id" "$tx_status_json")"

curl -fsS "$BASE_URL/wallets/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_wallet_after"

curl -fsS "$BASE_URL/wallets/$receiver_id" \
  -H "Authorization: Bearer $receiver_token" > "$receiver_wallet_after"

curl -fsS "$BASE_URL/notifications/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$sender_notifications"

curl -fsS "$BASE_URL/notifications/$receiver_id" \
  -H "Authorization: Bearer $receiver_token" > "$receiver_notifications"

sender_completed_notifications="$(
  jq --arg tx "$transaction_id" \
    '[.[] | select(.transaction_id == $tx and .type == "TRANSACTION_COMPLETED")] | length' \
    "$sender_notifications"
)"
receiver_received_notifications="$(
  jq --arg tx "$transaction_id" \
    '[.[] | select(.transaction_id == $tx and .type == "TRANSACTION_RECEIVED")] | length' \
    "$receiver_notifications"
)"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg senderEmail "$sender_email" \
  --arg receiverEmail "$receiver_email" \
  --arg senderId "$sender_id" \
  --arg receiverId "$receiver_id" \
  --arg transactionId "$transaction_id" \
  --arg status "$status" \
  --arg amount "$AMOUNT" \
  --arg senderBefore "$(jq -r '.balance' "$sender_wallet_before")" \
  --arg senderAfter "$(jq -r '.balance' "$sender_wallet_after")" \
  --arg receiverBefore "$(jq -r '.balance' "$receiver_wallet_before")" \
  --arg receiverAfter "$(jq -r '.balance' "$receiver_wallet_after")" \
  --argjson senderCompleted "$sender_completed_notifications" \
  --argjson receiverReceived "$receiver_received_notifications" \
  '{
    baseUrl: $baseUrl,
    senderEmail: $senderEmail,
    receiverEmail: $receiverEmail,
    senderId: $senderId,
    receiverId: $receiverId,
    transactionId: $transactionId,
    status: $status,
    amount: $amount,
    balances: {
      senderBefore: $senderBefore,
      senderAfter: $senderAfter,
      receiverBefore: $receiverBefore,
      receiverAfter: $receiverAfter
    },
    notifications: {
      senderCompleted: $senderCompleted,
      receiverReceived: $receiverReceived
    }
  }'

if [[ "$status" != "COMPLETED" ]]; then
  echo "Expected transaction to complete, got: $status" >&2
  exit 1
fi

if [[ "$sender_completed_notifications" -lt 1 || "$receiver_received_notifications" -lt 1 ]]; then
  echo "Expected sender and receiver notifications for transaction: $transaction_id" >&2
  exit 1
fi

echo "Send Money smoke test passed."
