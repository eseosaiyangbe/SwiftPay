# SwiftPay System Flow: How Money Moves

> **The Complete Picture**: Step-by-step explanation of how a transaction flows through the system, from user click to money transfer completion.

> **After you run the app:** Follow this doc in **Week 1** of [`LEARNING-PATH.md`](../LEARNING-PATH.md). UI URL is **`http://www.swiftpay.local`** on MicroK8s (ingress) or **`http://localhost:8081`** if you used optional Docker Compose.

---

## Table of Contents

1. [The Complete Transaction Flow](#the-complete-transaction-flow)
2. [How Money Moves](#how-money-moves)
3. [Duplicate Prevention](#duplicate-prevention)
4. [Reversals and Safety Nets](#reversals-and-safety-nets)
5. [Service Communication Patterns](#service-communication-patterns)
6. [What Each Component Does](#what-each-component-does)

---

## The Complete Transaction Flow

### Visual Flow Diagram

```
User clicks "Send $100"
    ↓
┌─────────────────────────────────────────┐
│ 1. FRONTEND (React)                    │
│    - User interface                    │
│    - Makes API call: POST /api/transactions │
└───────────────┬─────────────────────────┘
                │ HTTP
                ▼
┌─────────────────────────────────────────┐
│ 2. API GATEWAY                          │
│    ✅ Authenticate (JWT token)          │
│    ✅ Validate request                  │
│    ✅ Check Redis (idempotency)         │
│    ✅ Route to Transaction Service      │
└───────────────┬─────────────────────────┘
                │ HTTP
                ▼
┌─────────────────────────────────────────┐
│ 3. TRANSACTION SERVICE                  │
│    ✅ Create record in PostgreSQL       │
│       Status: PENDING                   │
│    ✅ Publish message to RabbitMQ       │
│    ✅ Return: "Transaction queued"     │
└───────────────┬─────────────────────────┘
                │
        ┌───────┴───────┐
        │               │
        ▼               ▼
┌──────────────┐  ┌──────────────┐
│ PostgreSQL   │  │  RabbitMQ    │
│ (PENDING)    │  │  (Message)   │
└──────────────┘  └───────┬───────┘
                          │
                          │ Worker consumes
                          ▼
┌─────────────────────────────────────────┐
│ 4. WORKER (Transaction Service)         │
│    ✅ Update: PENDING → PROCESSING     │
│    ✅ Check database (idempotency)     │
│    ✅ Call Wallet Service              │
└───────────────┬─────────────────────────┘
                │ HTTP
                ▼
┌─────────────────────────────────────────┐
│ 5. WALLET SERVICE                       │
│    ✅ Start database transaction        │
│    ✅ Lock sender's wallet              │
│    ✅ Lock receiver's wallet            │
│    ✅ Check sufficient funds             │
│    ✅ Debit sender: balance - 100       │
│    ✅ Credit receiver: balance + 100    │
│    ✅ Commit transaction                │
└───────────────┬─────────────────────────┘
                │ Success
                ▼
┌─────────────────────────────────────────┐
│ 6. WORKER (Transaction Service)       │
│    ✅ Update: PROCESSING → COMPLETED   │
│    ✅ Send ACK to RabbitMQ              │
│    ✅ Publish notification to RabbitMQ │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│ 7. NOTIFICATION SERVICE                 │
│    ✅ Consumes notification message    │
│    ✅ Sends email to users              │
└─────────────────────────────────────────┘
```

---

## How Money Moves

### The Database Transaction

**When Wallet Service receives transfer request:**

```sql
-- Step 1: Start database transaction
BEGIN;

-- Step 2: Lock sender's wallet (prevents concurrent modifications)
SELECT balance FROM wallets 
WHERE user_id = 'user-456' 
FOR UPDATE;  -- Row-level lock

-- Step 3: Lock receiver's wallet
SELECT balance FROM wallets 
WHERE user_id = 'john-123' 
FOR UPDATE;

-- Step 4: Check sufficient funds
-- (In code: if balance < amount, return error)

-- Step 5: Debit sender
UPDATE wallets 
SET balance = balance - 100, 
    updated_at = CURRENT_TIMESTAMP 
WHERE user_id = 'user-456';

-- Step 6: Credit receiver
UPDATE wallets 
SET balance = balance + 100, 
    updated_at = CURRENT_TIMESTAMP 
WHERE user_id = 'john-123';

-- Step 7: Commit (save all changes) or Rollback (cancel)
COMMIT;
```

**Why this matters:**

1. **Atomicity**: Either both updates happen, or neither
   - If debit succeeds but credit fails → Rollback (no money lost)
   - If both succeed → Commit (money transferred)

2. **Isolation**: Row locks prevent race conditions
   - Two transfers at once → One waits for the other
   - No double-spending

3. **Consistency**: Balances always add up
   - Total money in system never changes
   - Sender balance + Receiver balance = Same total

### Money Flow Example

**Before Transfer:**
```
User A: $500.00
User B: $200.00
Total:  $700.00
```

**Transfer: $100 from User A to User B**

**During Transfer (inside database transaction):**
```
User A: $500.00 → $400.00 (locked, can't be modified)
User B: $200.00 → $300.00 (locked, can't be modified)
Total:  $700.00 (unchanged)
```

**After Transfer (transaction committed):**
```
User A: $400.00
User B: $300.00
Total:  $700.00 (unchanged)
```

**If Transfer Fails (transaction rolled back):**
```
User A: $500.00 (unchanged)
User B: $200.00 (unchanged)
Total:  $700.00 (unchanged)
```

---

## Duplicate Prevention

### Two Layers of Safety

**Layer 1: Transaction Service (Redis) — Fast Duplicate Check**

> Note: This check runs inside **transaction-service** (not the API gateway) using a shared Redis idempotency manager. The API gateway routes the request in; transaction-service owns the duplicate detection.

**When**: Transaction service receives a create request

**How it works:**
```javascript
// See: services/transaction-service/server.js + services/shared/idempotency.js

const idempotencyKey = req.headers['idempotency-key'];
const key = idempotencyManager.generateKey(
  fromUserId,
  'create-transaction',
  { toUserId, amount }
);

// Check Redis: "Have we seen this key before?"
const result = await idempotencyManager.check(key, async () => {
  return await createTransaction(fromUserId, toUserId, amount);
});

// If fromCache: true, returns cached result (no duplicate transaction)
// If fromCache: false, processes and caches result
```

**What it prevents:**
- User double-clicks "Send" button
- Network retry sends request twice
- Browser refresh resubmits form

**Result**: Same request ID = same response (no duplicate transaction)

**Layer 2: Worker (Database) - Reliable Check**

**When**: Worker processes message from RabbitMQ

**How it works:**
```javascript
// Worker receives message from RabbitMQ
// See: services/transaction-service/server.js - processTransaction()

const transaction = JSON.parse(msg.content.toString());

// Before processing, check if transaction already exists
// This check happens in processTransaction() before updating status
// If transaction exists with status PROCESSING or COMPLETED, skip

// Actual implementation checks transaction status:
// - If status is PROCESSING: Transaction in progress, skip
// - If status is COMPLETED: Already done, acknowledge and skip
// - If status is PENDING: Proceed with processing

await processTransaction(transaction);
// Inside processTransaction():
// 1. Update status: PENDING → PROCESSING
// 2. Call Wallet Service (transfer money)
// 3. Update status: PROCESSING → COMPLETED
// 4. Send ACK to RabbitMQ
```

**What it prevents:**
- Worker crashes mid-processing, RabbitMQ retries
- Network issues cause duplicate messages
- Multiple workers process same message

**Result**: Same transaction ID = only processed once (no duplicate money movement)

### Why Two Layers?

**Scenario: User double-clicks "Send"**

**Without Layer 1 (Redis):**
```
Click 1 → Transaction Service → Creates TXN-123
Click 2 → Transaction Service → Creates TXN-124
Result: Two transactions created (user charged twice)
```

**With Layer 1 (Redis):**
```
Click 1 → API Gateway → Checks Redis → New → Creates TXN-123 → Caches result
Click 2 → API Gateway → Checks Redis → Exists → Returns cached result
Result: One transaction created (user charged once)
```

**Scenario: Worker crashes, RabbitMQ retries**

**Without Layer 2 (Database):**
```
Worker processes TXN-123 → Crashes mid-transfer
RabbitMQ retries → Worker processes TXN-123 again
Result: Money transferred twice
```

**With Layer 2 (Database):**
```
Worker processes TXN-123 → Crashes mid-transfer
Database: TXN-123 exists (status: PROCESSING)
RabbitMQ retries → Worker checks database → Already exists → Skip
Result: Money transferred once
```

---

## Reversals and Safety Nets

### Why Reversals Exist

**Problem**: Transactions can get stuck in PENDING state if:
- RabbitMQ is down (message never queued)
- Worker crashes (processing never completed)
- Network issues (can't reach wallet service)

**Without reversals:**
- User's money stuck in PENDING
- Can't use that money
- Support tickets flood in

**With reversals:**
- Stuck transactions automatically reversed
- User's money unblocked
- User can try again

### How Reversals Work

**CronJob runs every minute:**

```sql
-- Find transactions stuck in PENDING for more than 1 minute
UPDATE transactions
SET 
  status = 'FAILED',
  error_message = 'Transaction timeout - automatically reversed',
  completed_at = NOW()
WHERE 
  status = 'PENDING'                    -- Still pending
  AND created_at < NOW() - INTERVAL '1 minute'  -- Older than 1 minute
  AND NOT EXISTS (                      -- Safety check
    SELECT 1 
    FROM transactions t2 
    WHERE t2.from_user_id = transactions.from_user_id
    AND t2.status = 'COMPLETED'
    AND t2.created_at > transactions.created_at
  );
```

**What this does:**
1. Finds transactions: `status = 'PENDING'` AND `created_at < NOW() - 1 minute`
2. Marks them as FAILED
3. User's money is unblocked (status changed, no money was moved)

**Why 1 minute?**
- Normal transactions: 2-5 seconds
- With retries: 10-15 seconds
- 1 minute: Catches stuck transactions without false positives

### Reversal Flow

```
Transaction created: 10:00:00 (status: PENDING)
RabbitMQ is down → Message not queued
10:01:00 → CronJob runs
10:01:00 → Finds stuck transaction
10:01:00 → Updates: PENDING → FAILED
User's money unblocked (can try again)
```

---

## Service Communication Patterns

### Pattern 1: Synchronous (HTTP) - Immediate Response Needed

**Used for:**
- User authentication (need to know if login succeeded)
- Balance checks (user is waiting for balance)
- Creating transactions (user needs transaction ID)

**Flow:**
```
Frontend → API Gateway → Auth Service
         (waits)        (waits)
         ←──────────────←
```

**Example: Login**
```
1. Frontend: POST /api/auth/login
2. API Gateway: Forwards to Auth Service
3. Auth Service: Validates credentials, returns JWT token
4. API Gateway: Returns token to frontend
5. Frontend: Stores token, shows dashboard
```

**Why synchronous:**
- User needs immediate feedback
- Can't proceed without result
- Simple request/response pattern

### Pattern 2: Asynchronous (RabbitMQ) - Can Process Later

**Used for:**
- Transaction processing (user doesn't need to wait)
- Notifications (email can be sent later)
- Analytics (can be processed later)

**Flow:**
```
Transaction Service → RabbitMQ → Notification Service
                    (doesn't wait)
```

**Example: Transaction Notification**
```
1. Transaction completes
2. Transaction Service: Publishes message to RabbitMQ
3. Transaction Service: Continues (doesn't wait)
4. Notification Service: Consumes message later
5. Notification Service: Sends email
```

**Why asynchronous:**
- User doesn't need to wait
- Services can be down temporarily
- Can handle traffic spikes (messages queue up)

---

## What Each Component Does

### API Gateway

**Purpose**: Single entry point for all API requests

**What it does:**
1. **Authentication**: Verifies JWT tokens
2. **Validation**: Checks request format
3. **Idempotency**: Checks Redis for duplicate requests
4. **Routing**: Forwards requests to correct service
5. **Rate Limiting**: Prevents abuse

**Why it exists:**
- Without it: Frontend calls multiple services directly
- With it: Single point of control, consistent behavior

### Transaction Service

**Purpose**: Manages transaction lifecycle

**What it does:**
1. **Creates transactions**: Writes to PostgreSQL (status: PENDING)
2. **Queues work**: Publishes to RabbitMQ
3. **Processes transactions**: Worker consumes from RabbitMQ
4. **Updates status**: PENDING → PROCESSING → COMPLETED

**Why it exists:**
- Separates transaction creation from processing
- Allows async processing (user doesn't wait)
- Handles retries and failures

### Wallet Service

**Purpose**: Manages user wallets and balances

**What it does:**
1. **Creates wallets**: New user gets a wallet
2. **Checks balance**: Returns current balance
3. **Transfers money**: Updates balances atomically
4. **Caches balances**: Stores in Redis for fast access

**Why it exists:**
- Centralized balance management
- Ensures atomic transfers (database transactions)
- Provides fast balance checks (Redis cache)

### RabbitMQ

**Purpose**: Message queue for async processing

**What it does:**
1. **Stores messages**: Holds work until workers are ready
2. **Distributes work**: Gives messages to workers
3. **Handles retries**: Retries failed messages
4. **Dead Letter Queue**: Stores permanently failed messages

**Why it exists:**
- Decouples services (don't need to be available at same time)
- Handles traffic spikes (messages queue up)
- Survives service restarts (messages persist)

### Redis

**Purpose**: Fast cache and idempotency store

**What it does:**
1. **Caches balances**: Fast balance lookups
2. **Idempotency keys**: Prevents duplicate requests
3. **Session storage**: User sessions
4. **Rate limiting**: Tracks API request counts

**Why it exists:**
- Fast lookups (microseconds vs milliseconds)
- Reduces database load
- Prevents duplicate charges

### PostgreSQL

**Purpose**: Reliable storage for money and transactions

**What it does:**
1. **Stores users**: User accounts and credentials
2. **Stores wallets**: User balances
3. **Stores transactions**: Transaction history
4. **ACID transactions**: Guarantees consistency

**Why it exists:**
- Reliable (ACID guarantees)
- Consistent (no data corruption)
- Persistent (data survives restarts)

---

## Summary

### The Flow in One Sentence

**User clicks "Send" → API Gateway validates → Transaction Service creates record → RabbitMQ queues work → Worker processes → Wallet Service transfers money → Transaction completes → Notification sent**

### Key Principles

1. **Write before doing**: Create transaction record before processing
2. **Queue work**: Don't process immediately, queue it
3. **Check for duplicates**: At API level (Redis) and worker level (Database)
4. **Atomic transfers**: Database transactions ensure money moves correctly
5. **Safety nets**: CronJob reverses stuck transactions

### Why This Architecture Works

- **Fast**: User gets immediate response (100ms)
- **Reliable**: Messages persist, retries work
- **Safe**: Duplicate prevention at two layers
- **Scalable**: Can handle traffic spikes (messages queue up)
- **Resilient**: Services can restart without losing work

---

*Understanding the flow helps you debug issues, add features, and explain the system to others.*

---

**Read next:**
- [`docs/SERVICES.md`](SERVICES.md) — deep dive into each service: what it owns, its key logic, and why it exists separately
- [`docs/microk8s-deployment.md`](microk8s-deployment.md) — deploy this system to Kubernetes and see the flow running live
- [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — when something in the flow breaks, start here
