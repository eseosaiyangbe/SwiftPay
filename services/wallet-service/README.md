# Wallet Service

**Port:** 3001 | **File:** `server.js` (620 lines)

## What this service owns

- **`wallets` table** — one row per user, stores balance and currency
- **Redis keys** — `wallet:{userId}` (cached balance, 60s TTL), `wallets:all` (full list, 30s TTL)

## Why it exists separately

Money movement is the most dangerous operation in a payment system. The wallet service is the **only** thing that can change a balance. It does this using PostgreSQL row locks (`SELECT ... FOR UPDATE`) inside a transaction, so two concurrent transfers to the same wallet can't corrupt each other.

By isolating this logic here, the transaction service can call it over HTTP and trust a simple contract: the transfer either succeeds (HTTP 200) or fails (HTTP 4xx/5xx) — it never partially succeeds or silently corrupts data. This is how fintech companies separate **ledger** *(the authoritative record of who has what balance)* from **payment orchestration** *(deciding when and how to trigger a transfer)*.

## How atomic transfers work

```sql
BEGIN;
  -- Lock both rows to prevent concurrent modifications
  SELECT balance FROM wallets WHERE user_id = $sender  FOR UPDATE;
  SELECT balance FROM wallets WHERE user_id = $receiver FOR UPDATE;

  -- Check funds (application layer)
  -- Debit sender
  UPDATE wallets SET balance = balance - $amount WHERE user_id = $sender;
  -- Credit receiver
  UPDATE wallets SET balance = balance + $amount WHERE user_id = $receiver;
COMMIT;
-- If anything fails, PostgreSQL auto-rolls back both updates
```

Either both updates happen or neither does. This is ACID atomicity in action.

## Most interesting code to read first

| Where | What it teaches |
|-------|----------------|
| `POST /wallets/transfer` | The core atomic transfer — row locking, balance check, debit+credit in one transaction |
| Redis cache middleware | Cache-aside pattern — check Redis first, fall back to Postgres, write back to cache |
| Pool query wrapper | How to instrument every DB query for Prometheus metrics without repeating code |
| `GET /wallets/:userId/balance` | Cache TTL strategy — balance cached for 10s (short — money moves), wallet object for 60s |

## Run it locally

```bash
cd ../..
docker compose up -d postgres redis
cd services/wallet-service
npm install
npm run dev   # starts on port 3001
```

Or use the VS Code **"Debug Wallet Service"** launch config.

## Health check

```bash
curl http://localhost:3001/health
# {"status":"healthy","postgres":"connected","redis":"connected"}
```

## Things to think about

- Why are both wallets locked before checking the balance? (Hint: what happens if you only lock one?)
- Why is the balance cache TTL only 10 seconds? What would break if it was 10 minutes?
- The transfer endpoint has no auth check — why is that safe? *(Hint: it's on an internal-only network. In Docker/K8s, only transaction-service can reach it — there's no route from the public internet to this port.)*

---

**Read next:** [`services/transaction-service`](../transaction-service/README.md) — learn how the wallet transfer is triggered asynchronously, and what happens when it fails mid-flight.
