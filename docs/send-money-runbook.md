# SwiftPay Send Money Runbook

This is the operational runbook for SwiftPay's core money movement path.

Use this document when you want to prove that Send Money works, explain how money moves through the system, or debug a transfer that is stuck, failed, or missing notifications.

## Current Verified Baseline

The Send Money path has been verified locally with Docker Compose through the real API Gateway.

Verified command:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:send-money
```

Verified result:

```json
{
  "status": "COMPLETED",
  "amount": "25.50",
  "balances": {
    "senderBefore": "1000.00",
    "senderAfter": "974.50",
    "receiverBefore": "1000.00",
    "receiverAfter": "1025.50"
  },
  "notifications": {
    "senderCompleted": 1,
    "receiverReceived": 1
  }
}
```

What this proves:

- API Gateway accepts authenticated transfer requests.
- Auth tokens are valid.
- Wallets are created for new users.
- Transaction Service creates a `PENDING` transaction.
- RabbitMQ delivers the transaction message to the worker.
- Worker claims only `PENDING` transactions.
- Wallet Service moves money atomically.
- Transaction Service marks the transaction `COMPLETED`.
- Notification messages are published.
- Notification Service stores sender and receiver notifications.

## Runtime Services

Docker Compose host ports:

| Service | URL |
|---|---|
| Frontend | `http://localhost:8081` |
| API Gateway | `http://localhost:3007/health` |
| Auth Service | `http://localhost:3004/health` |
| Wallet Service | `http://localhost:3001/health` |
| Transaction Service | `http://localhost:3008/health` |
| Notification Service | `http://localhost:3003/health` |
| RabbitMQ UI | `http://localhost:15672` |

RabbitMQ local credentials:

```text
swiftpay / swiftpay123
```

## Happy Path

The verified money path:

```text
1. User registers or logs in.
2. API Gateway sends auth request to Auth Service.
3. Auth Service creates the user and returns JWT tokens.
4. API Gateway creates the user's default wallet in Wallet Service.
5. User sends money through POST /api/transactions.
6. API Gateway authenticates the JWT.
7. API Gateway confirms the sender owns fromUserId.
8. API Gateway forwards the request to Transaction Service.
9. Transaction Service writes a PENDING transaction to PostgreSQL.
10. Transaction Service publishes a message to RabbitMQ.
11. Transaction Service returns "Transaction queued for processing".
12. Transaction worker consumes the RabbitMQ message.
13. Worker locks the transaction row.
14. Worker skips the message unless the transaction is still PENDING.
15. Worker marks the transaction PROCESSING.
16. Worker calls Wallet Service.
17. Wallet Service starts a PostgreSQL transaction.
18. Wallet Service locks both wallets in a stable order.
19. Wallet Service verifies sender has enough funds.
20. Wallet Service debits sender and credits receiver.
21. Wallet Service commits the database transaction.
22. Transaction Service marks the transaction COMPLETED.
23. Transaction Service publishes sender and receiver notification messages.
24. Notification Service stores the notifications.
25. Frontend polling shows the new balance, activity, and notifications.
```

## Run The Smoke Test

Run:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:send-money
```

The script lives at:

```text
scripts/smoke-send-money.sh
```

It creates fresh users each time using unique emails:

```text
smoke.sender.<timestamp>@swiftpay.local
smoke.receiver.<timestamp>@swiftpay.local
```

The default transfer amount is:

```text
25.50
```

Override the amount:

```bash
SMOKE_AMOUNT=10.25 npm run smoke:send-money
```

Override the API base URL:

```bash
BASE_URL=http://localhost:3007/api npm run smoke:send-money
```

This will be useful when we move from Docker Compose to Kubernetes and later Cloudflared.

## Run A Failed Transaction Smoke Test

The UI blocks over-balance transfers before calling the backend. That is good user experience, but it means entering more than the available balance in the UI does not create a `FAILED` transaction row.

To create a real failed transaction for testing, use the backend smoke test:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:failed-transaction
```

The script creates two fresh users, then sends more money than the sender has.

Expected result:

```text
status: FAILED
error: Insufficient funds
senderBefore: 1000.00
senderAfter: 1000.00
receiverBefore: 1000.00
receiverAfter: 1000.00
senderFailed: 1
```

Override the failed amount:

```bash
SMOKE_FAILED_AMOUNT=2000.00 npm run smoke:failed-transaction
```

## Run A Notification Smoke Test

The notification smoke test verifies the frontend-facing notification lifecycle through the real API Gateway.

Run:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:notifications
```

What it proves:

- A completed Send Money transaction creates a sender notification.
- The notification starts unread.
- `PUT /api/notifications/:id/read` marks the notification as read.
- A follow-up notification fetch returns `read: true`.
- `DELETE /api/notifications/:id` deletes the notification.
- A follow-up notification fetch no longer returns the deleted notification.

Expected result:

```text
status: COMPLETED
readBefore: false
readAfter: true
readAfterFetch: true
deleted: true
remainingCount: 0
```

Override the notification test amount:

```bash
SMOKE_NOTIFICATION_AMOUNT=3.25 npm run smoke:notifications
```

## Expected Good Result

A good run should end with:

```text
Send Money smoke test passed.
```

The JSON should show:

```text
status: COMPLETED
senderBefore: 1000.00
senderAfter: 974.50
receiverBefore: 1000.00
receiverAfter: 1025.50
senderCompleted: 1
receiverReceived: 1
```

If those values are true, the full money path is healthy.

## Database Verification

Check recent transactions:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select id, status, amount, from_user_id, to_user_id, error_message, created_at, completed_at
from transactions
order by created_at desc
limit 10;
"
```

Check transaction counts:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select status, count(*)
from transactions
group by status
order by status;
"
```

Check notifications:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select type, user_id, transaction_id, message, read, created_at
from notifications
order by created_at desc
limit 10;
"
```

Check wallet balances for a known pair:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select user_id, name, balance, updated_at
from wallets
order by updated_at desc
limit 10;
"
```

## Health Checks

Run:

```bash
curl -fsS http://localhost:3007/health
curl -fsS http://localhost:3004/health
curl -fsS http://localhost:3001/health
curl -fsS http://localhost:3008/health
curl -fsS http://localhost:3003/health
```

Transaction Service should include:

```text
database: connected
rabbitmq: connected
circuitBreaker: closed
```

Check the Compose stack:

```bash
docker compose ps
```

Expected:

```text
api-gateway            healthy
auth-service           healthy
wallet-service         healthy
transaction-service    healthy
notification-service   healthy
postgres               healthy
redis                  healthy
rabbitmq               healthy
frontend               healthy
```

## Troubleshooting

### npm Is Not Found

Do not install npm with `apt`.

Load `nvm`:

```bash
source ~/.nvm/nvm.sh
node --version
npm --version
```

Then rerun:

```bash
npm run smoke:send-money
```

### Transaction Stays PENDING

This usually means the request was accepted, but the worker did not complete it.

Check Transaction Service health:

```bash
curl -fsS http://localhost:3008/health
```

Check Transaction Service logs:

```bash
docker compose logs transaction-service --tail=100
```

Check RabbitMQ:

```bash
docker compose ps rabbitmq
docker compose logs rabbitmq --tail=100
```

Check queue depth:

```bash
curl -fsS http://localhost:3008/metrics/queue
```

### Transaction Becomes FAILED

Check the error:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select id, status, amount, error_message, created_at, completed_at
from transactions
where status = 'FAILED'
order by created_at desc
limit 10;
"
```

Common causes:

- Wallet Service is down.
- Sender does not have enough funds.
- Sender or receiver wallet is missing.
- Transaction Service circuit breaker is open.

Check Wallet Service:

```bash
curl -fsS http://localhost:3001/health
docker compose logs wallet-service --tail=100
```

### Balances Do Not Change

Check whether the transaction completed:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select id, status, amount, from_user_id, to_user_id
from transactions
order by created_at desc
limit 5;
"
```

If status is `PENDING`, debug Transaction Service and RabbitMQ.

If status is `FAILED`, inspect `error_message`.

If status is `COMPLETED`, check Wallet Service cache and query the database directly:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select user_id, balance
from wallets
order by updated_at desc
limit 10;
"
```

### Notifications Are Missing

Check Notification Service:

```bash
curl -fsS http://localhost:3003/health
docker compose logs notification-service --tail=100
```

Check notification rows:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -c "
select type, user_id, transaction_id, message, created_at
from notifications
order by created_at desc
limit 20;
"
```

If the transaction completed but no notification rows exist, inspect Transaction Service logs first, then Notification Service logs.

## Code Ownership Map

Important files:

| File | Purpose |
|---|---|
| `services/frontend/src/App.js` | User interface and frontend API calls |
| `services/api-gateway/server.js` | Public API boundary, auth, authorization, routing |
| `services/api-gateway/middleware/auth.js` | JWT verification and owner checks |
| `services/auth-service/server.js` | User registration, login, token handling |
| `services/wallet-service/server.js` | Wallet API and transfer endpoint |
| `services/wallet-service/wallet-transfer.js` | Atomic debit/credit logic |
| `services/transaction-service/server.js` | Transaction API, RabbitMQ worker, queue handling |
| `services/transaction-service/transaction-guard.js` | Duplicate message/status guard |
| `services/transaction-service/transaction-finalizer.js` | Completion/failure finalization |
| `services/notification-service/server.js` | Notification consumer and notification API |
| `scripts/smoke-send-money.sh` | Repeatable end-to-end Send Money smoke test |

## Tests Related To This Flow

Wallet Service:

```bash
cd services/wallet-service
npm run test:unit
```

Transaction Service:

```bash
cd services/transaction-service
npm run test:unit
```

End-to-end smoke:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:send-money
```

## Kubernetes And Cloudflared Notes

When we move from Docker Compose to Kubernetes, this runbook still applies.

The command changes only by setting `BASE_URL`:

```bash
BASE_URL=http://www.swiftpay.local/api npm run smoke:send-money
```

Later, when exposed through Cloudflared, the same smoke test should target the public tunnel URL:

```bash
BASE_URL=https://<swiftpay-domain>/api npm run smoke:send-money
```

This gives us one reusable acceptance test across:

- Docker Compose.
- Local Kubernetes.
- Cloudflared.
- Future cloud environments.
