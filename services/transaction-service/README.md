# Transaction Service

**Port:** 3002 | **File:** `server.js` (899 lines) — the most complex service

## What this service owns

- **`transactions` table** — every payment attempt with status, timestamps, idempotency key
- **Redis keys** — `idempotency:{userId}:create-transaction:{params}` (24h TTL, prevents duplicate charges)
- **RabbitMQ queues** — publishes to `transactions`, consumes from `transactions`, dead-letters to `transactions.dlq`

## Why it exists separately

Sending money isn't instant. It involves: record the intent → lock funds → debit → credit → notify. If you did all that synchronously and anything timed out (network blip, database slow moment), the user would see an error even though some of those steps might have completed.

The transaction service separates **accepting the request** (fast, synchronous — milliseconds) from **processing it** (slower, async via RabbitMQ). The user gets "transaction received" immediately. The actual money movement happens reliably in the background. This is how Venmo, Cash App, and most payment systems work.

## The full flow for one Send Money click

```
1. POST /transactions (HTTP, synchronous)
   ├── Check idempotency key in Redis → if duplicate, return existing transaction
   ├── INSERT transaction row (status: PENDING)
   ├── Publish message to RabbitMQ `transactions` queue
   └── Return {transactionId, status: "PENDING"} to user immediately

2. RabbitMQ worker (async, separate process within the service)
   ├── Consume message from queue
   ├── UPDATE status → PROCESSING
   ├── Call wallet-service POST /wallets/transfer (via circuit breaker)
   │   ├── Success → UPDATE status → COMPLETED
   │   └── Failure → retry up to 3x, then → transactions.dlq + UPDATE status → FAILED
   └── Publish to `notifications` queue → notification-service picks it up
```

## Most interesting code to read first

| Where | What it teaches |
|-------|----------------|
| RabbitMQ connection setup (~line 135) | Exponential backoff reconnect — what happens when the queue restarts |
| `CircuitBreaker` setup (~line 87) | Opossum (`opossum` npm) circuit breaker — opens after 50% error rate, stops calling wallet-service so it can recover instead of being hammered |
| `POST /transactions` handler | Idempotency check, PENDING insert, publish — the "accept fast" half |
| RabbitMQ consumer | The "process reliably" half — ack/nack, retry logic, DLQ |
| Dead letter queue setup | What happens to messages that fail 3 times — visibility for ops |

## Run it locally

```bash
cd ../..
docker compose up -d postgres redis rabbitmq
cd services/transaction-service
npm install
npm run dev   # starts on port 3002
```

Or use the VS Code **"Debug Transaction Service"** launch config.

## Health check

```bash
curl http://localhost:3002/health
# {"status":"healthy","postgres":"connected","rabbitmq":"connected","circuitBreaker":"closed"}
```

## Key concepts to understand here

- **Idempotency** — if you POST the same transaction twice (network retry, double-click), only one transfer goes through. The idempotency key is derived from `userId + amount + recipientId`.
- **Circuit breaker** — if wallet-service starts failing, the circuit "opens" and stops calling it, giving it time to recover instead of hammering it with retries.
- **Dead letter queue (DLQ)** — messages that fail after 3 retries go to `transactions.dlq` so ops can inspect them rather than silently losing them. "Dead letter" = a message that couldn't be delivered and was set aside.
- **Message acknowledgement** — the worker only `ack`s (acknowledges = "I processed this successfully, remove it from the queue") a message after the wallet transfer succeeds. If the worker crashes mid-flight, RabbitMQ requeues the message automatically. `nack` = "I failed, put it back."

## Things to think about

- What would happen if the service crashed between "INSERT PENDING" and "publish to queue"? How would you detect that?
- Why does the idempotency key have a 24h TTL? What's the trade-off?
- The circuit breaker opens at 50% error rate. Why not 100%?

---

**Read next:** [`services/notification-service`](../notification-service/README.md) — see what happens after the transfer completes: how the event-driven notification pipeline works.
