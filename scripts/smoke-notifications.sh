#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3007/api}"
PASSWORD="${SMOKE_PASSWORD:-SwiftPay123}"
AMOUNT="${SMOKE_NOTIFICATION_AMOUNT:-6.75}"
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
notifications_before="$(mktemp)"
notification_read_json="$(mktemp)"
notifications_after_read="$(mktemp)"
notification_delete_json="$(mktemp)"
notifications_after_delete="$(mktemp)"

cleanup() {
  rm -f \
    "$sender_json" \
    "$receiver_json" \
    "$tx_json" \
    "$tx_status_json" \
    "$notifications_before" \
    "$notification_read_json" \
    "$notifications_after_read" \
    "$notification_delete_json" \
    "$notifications_after_delete"
}
trap cleanup EXIT

sender_email="notify.sender.${STAMP}@swiftpay.local"
receiver_email="notify.receiver.${STAMP}@swiftpay.local"

curl -fsS -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$sender_email\",\"password\":\"$PASSWORD\",\"name\":\"Notify Sender $STAMP\"}" > "$sender_json"

curl -fsS -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$receiver_email\",\"password\":\"$PASSWORD\",\"name\":\"Notify Receiver $STAMP\"}" > "$receiver_json"

sender_id="$(jq -r '.user.id' "$sender_json")"
receiver_id="$(jq -r '.user.id' "$receiver_json")"
sender_token="$(jq -r '.accessToken' "$sender_json")"

curl -fsS -X POST "$BASE_URL/transactions" \
  -H "Authorization: Bearer $sender_token" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: notifications-${STAMP}" \
  -d "{\"fromUserId\":\"$sender_id\",\"toUserId\":\"$receiver_id\",\"amount\":$AMOUNT}" > "$tx_json"

transaction_id="$(jq -r '.id' "$tx_json")"
status="$(wait_for_transaction "$sender_token" "$transaction_id" "$tx_status_json")"

curl -fsS "$BASE_URL/notifications/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$notifications_before"

notification_id="$(
  jq -r --arg tx "$transaction_id" \
    '[.[] | select(.transaction_id == $tx and .type == "TRANSACTION_COMPLETED")][0].id // empty' \
    "$notifications_before"
)"

if [[ -z "$notification_id" ]]; then
  echo "Expected sender completion notification for transaction: $transaction_id" >&2
  exit 1
fi

read_before="$(
  jq -r --argjson id "$notification_id" \
    '.[] | select(.id == $id) | .read' \
    "$notifications_before"
)"

curl -fsS -X PUT "$BASE_URL/notifications/$notification_id/read" \
  -H "Authorization: Bearer $sender_token" \
  -H "Content-Type: application/json" \
  -d '{}' > "$notification_read_json"

read_after="$(jq -r '.read' "$notification_read_json")"

curl -fsS "$BASE_URL/notifications/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$notifications_after_read"

read_after_fetch="$(
  jq -r --argjson id "$notification_id" \
    '.[] | select(.id == $id) | .read' \
    "$notifications_after_read"
)"

curl -fsS -X DELETE "$BASE_URL/notifications/$notification_id" \
  -H "Authorization: Bearer $sender_token" > "$notification_delete_json"

deleted="$(jq -r '.deleted' "$notification_delete_json")"

curl -fsS "$BASE_URL/notifications/$sender_id" \
  -H "Authorization: Bearer $sender_token" > "$notifications_after_delete"

remaining_count="$(
  jq --argjson id "$notification_id" \
    '[.[] | select(.id == $id)] | length' \
    "$notifications_after_delete"
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
  --argjson notificationId "$notification_id" \
  --arg readBefore "$read_before" \
  --arg readAfter "$read_after" \
  --arg readAfterFetch "$read_after_fetch" \
  --arg deleted "$deleted" \
  --argjson remainingCount "$remaining_count" \
  '{
    baseUrl: $baseUrl,
    senderEmail: $senderEmail,
    receiverEmail: $receiverEmail,
    senderId: $senderId,
    receiverId: $receiverId,
    transactionId: $transactionId,
    status: $status,
    amount: $amount,
    notification: {
      id: $notificationId,
      readBefore: $readBefore,
      readAfter: $readAfter,
      readAfterFetch: $readAfterFetch,
      deleted: $deleted,
      remainingCount: $remainingCount
    }
  }'

if [[ "$status" != "COMPLETED" ]]; then
  echo "Expected transaction to complete, got: $status" >&2
  exit 1
fi

if [[ "$read_before" != "false" ]]; then
  echo "Expected notification to start unread, got: $read_before" >&2
  exit 1
fi

if [[ "$read_after" != "true" || "$read_after_fetch" != "true" ]]; then
  echo "Expected notification to be read after mark-read action" >&2
  exit 1
fi

if [[ "$deleted" != "true" || "$remaining_count" -ne 0 ]]; then
  echo "Expected notification to be deleted" >&2
  exit 1
fi

echo "Notifications smoke test passed."
