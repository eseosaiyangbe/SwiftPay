# Tracing a Single Request Through PayFlow

> **Phase 2 - Flow & Mental Models** - Read this after Phase 1. Most important doc for understanding the system.

This document follows one real request end-to-end. Understanding this flow is more valuable than knowing every tool.

---

## Why This Matters

When something breaks, you need to know where to look. Tracing a request teaches you:

- Which services are involved
- Where data is read and written
- Where failures commonly occur
- Why the system is built this way

This is more valuable than memorizing commands. Commands change. The flow doesn't.

---

## The Request: Send $100

A user wants to send $100 to another user. Let's follow this request from the browser to completion.

---

## Step 1: The Browser Makes a Request

**What happens:**

The user clicks "Send Money" in the React frontend. The frontend makes an HTTP request:

```
POST https://www.payflow.local/api/transactions
Headers:
  Authorization: Bearer <jwt-token>
  Content-Type: application/json
Body:
  {
    "toUserId": "user-456",
    "amount": 100
  }
```

**What the frontend does:**

- Reads the form data (recipient, amount)
- Gets the JWT token from localStorage (from previous login)
- Makes the HTTP request
- Shows "Processing..." to the user

**What the frontend doesn't do:**

- Validate the amount (API Gateway does this)
- Check if user has enough money (Wallet Service does this)
- Actually move money (Wallet Service does this)

**Why this matters:**

The frontend is just a UI. It doesn't contain business logic. This is intentional - business logic lives in services.

---

## Step 2: The Request Hits the API Gateway

**What happens:**

The request arrives at the API Gateway (running on port 80, exposed via ingress).

**What the API Gateway checks (in order):**

1. **Security headers** - Adds protection headers (automatic)
2. **CORS** - Is the origin allowed? (usually yes in development)
3. **Rate limiting** - Has this IP made too many requests? (checks Redis)
4. **Request validation** - Is the data format correct?
   - `toUserId` must be a non-empty string
   - `amount` must be a number between 0.01 and 1,000,000
5. **Authentication** - Is the user logged in?
   - Extracts JWT token from `Authorization` header
   - Calls Auth Service: `POST /auth/verify`
   - Auth Service validates token and returns user info
   - If valid, adds `req.user` to the request
6. **Authorization** - Can this user make this request?
   - Checks if `req.user.userId` matches the sender (user can only send from their own wallet)
   - Admin users can bypass this check

**If any check fails:**

The API Gateway returns an error immediately. The request never reaches Transaction Service.

**If all checks pass:**

The API Gateway forwards the request to Transaction Service:

```
POST http://transaction-service:3002/transactions
Body:
  {
    "fromUserId": "user-123",  // Added by API Gateway from JWT token
    "toUserId": "user-456",
    "amount": 100
  }
```

**Why the API Gateway exists:**

Without it, each service would need to:
- Handle authentication (duplicated code)
- Validate requests (duplicated code)
- Rate limit (duplicated code)
- Handle CORS (duplicated code)

The API Gateway does this once, so services don't have to.

---

## Step 3: Transaction Service Creates a Record

**What happens:**

Transaction Service receives the request and does two things:

1. **Creates a database record:**
   ```sql
   INSERT INTO transactions (id, from_user_id, to_user_id, amount, status)
   VALUES ('TXN-123', 'user-123', 'user-456', 100, 'PENDING')
   ```

2. **Publishes a message to RabbitMQ:**
   ```javascript
   channel.sendToQueue('transactions', {
     id: 'TXN-123',
     from_user_id: 'user-123',
     to_user_id: 'user-456',
     amount: 100
   })
   ```

3. **Returns immediately:**
   ```json
   {
     "id": "TXN-123",
     "status": "PENDING",
     "message": "Transaction queued for processing"
   }
   ```

**Why two steps:**

- Database record = Permanent record (survives restarts)
- RabbitMQ message = Work to do (queued for processing)

If RabbitMQ is down, the database record still exists. The system can recover.

**Why return immediately:**

The user doesn't need to wait for money to move. They get instant feedback. The actual work happens in the background.

---

## Step 4: The User Sees "Processing"

**What happens:**

The API Gateway returns the response to the frontend. The frontend shows "Transaction processing..." to the user.

**What the user doesn't know:**

- Money hasn't moved yet
- The transaction is just queued
- A worker will process it soon

**Why this is okay:**

Users don't need to wait. They get instant feedback. The system processes the transaction asynchronously.

---

## Step 5: Worker Picks Up the Message

**What happens (background):**

A worker (part of Transaction Service) consumes the message from RabbitMQ:

```javascript
channel.consume('transactions', async (msg) => {
  const transaction = JSON.parse(msg.content.toString());
  await processTransaction(transaction);
  channel.ack(msg); // Tell RabbitMQ: "I'm done, remove this message"
});
```

**Before processing, the worker checks:**

- Has this transaction already been processed? (idempotency check)
  - Queries database: `SELECT * FROM transactions WHERE id = 'TXN-123'`
  - If status is PROCESSING or COMPLETED, skip (already done)
  - If status is PENDING, proceed

**Why this check matters:**

If the worker crashes mid-processing, RabbitMQ will retry. Without this check, the transaction would be processed twice.

---

## Step 6: Worker Updates Status

**What happens:**

The worker updates the transaction status:

```sql
UPDATE transactions
SET status = 'PROCESSING', processing_started_at = NOW()
WHERE id = 'TXN-123'
```

**Why update status:**

- Shows the transaction is being worked on
- If worker crashes, we know it was processing (not stuck in PENDING)
- Helps with debugging (can see where it got stuck)

---

## Step 7: Worker Calls Wallet Service

**What happens:**

The worker calls Wallet Service to actually move the money:

```
POST http://wallet-service:3001/wallets/transfer
Body:
  {
    "fromUserId": "user-123",
    "toUserId": "user-456",
    "amount": 100
  }
```

**Why a separate service:**

Transaction Service manages transactions (records, status, queuing). Wallet Service manages money (balances, transfers). Separation of concerns.

**What Wallet Service does:**

1. Starts a database transaction (BEGIN)
2. Locks sender's wallet (SELECT ... FOR UPDATE)
3. Locks receiver's wallet (SELECT ... FOR UPDATE)
4. Checks sufficient funds
5. Debits sender: `UPDATE wallets SET balance = balance - 100 WHERE user_id = 'user-123'`
6. Credits receiver: `UPDATE wallets SET balance = balance + 100 WHERE user_id = 'user-456'`
7. Commits the transaction (COMMIT)

**Why database transactions matter:**

If step 5 succeeds but step 6 fails, the database transaction rolls back. Money doesn't disappear. Either both updates happen, or neither.

**Why row locking matters:**

If two transfers happen at the same time, row locks prevent race conditions. One transfer waits for the other.

---

## Step 8: Worker Updates Status to Completed

**What happens:**

After Wallet Service confirms the transfer succeeded, the worker updates the transaction:

```sql
UPDATE transactions
SET status = 'COMPLETED', completed_at = NOW()
WHERE id = 'TXN-123'
```

**Then sends ACK to RabbitMQ:**

```javascript
channel.ack(msg); // Message removed from queue
```

**Why ACK matters:**

If the worker doesn't send ACK, RabbitMQ assumes the message wasn't processed and will retry. ACK tells RabbitMQ: "I'm done, you can delete this message."

---

## Step 9: Notification is Sent (Async)

**What happens (background):**

The worker publishes a notification message to RabbitMQ:

```javascript
channel.sendToQueue('notifications', {
  userId: 'user-123',
  type: 'TRANSACTION_COMPLETED',
  message: 'You sent $100 to user-456'
});
```

**Notification Service consumes the message later and sends an email.**

**Why async:**

The user doesn't need to wait for the email. The transaction is done. The email can be sent whenever.

---

## Where Data Lives

**During this flow, data is read/written in:**

1. **PostgreSQL:**
   - Transaction record created (PENDING)
   - Transaction record updated (PROCESSING)
   - Wallet balances updated (debit sender, credit receiver)
   - Transaction record updated (COMPLETED)

2. **Redis:**
   - Rate limiting counters (API Gateway checks)
   - Session data (if applicable)
   - Idempotency keys (if provided)

3. **RabbitMQ:**
   - Transaction message (queued, then consumed)
   - Notification message (queued, consumed later)

**Why this matters:**

If you're debugging, you need to know where to look:
- Transaction stuck? Check PostgreSQL (status column)
- Rate limiting issues? Check Redis
- Message not processed? Check RabbitMQ queue depth

---

## Where Failures Commonly Occur

**1. API Gateway checks fail:**
- Invalid token → 401 Authentication required
- Rate limit exceeded → 429 Too Many Requests
- Validation failed → 400 Bad Request

**2. Transaction Service fails:**
- Database connection lost → Transaction record not created
- RabbitMQ down → Message not queued (transaction stays PENDING)

**3. Worker fails:**
- Crashes mid-processing → RabbitMQ retries (idempotency check prevents duplicate)
- Wallet Service down → Transfer fails, transaction marked FAILED

**4. Wallet Service fails:**
- Insufficient funds → Returns error, transaction marked FAILED
- Database transaction fails → Rollback, no money moved

**5. Network issues:**
- Service A can't reach Service B → Timeout, error returned
- Circuit breaker opens → Requests rejected immediately

**How to debug:**

Start at the failure point and work backward. If Wallet Service fails, check:
- Is Wallet Service running?
- Can it connect to PostgreSQL?
- Are there sufficient funds?
- Is the database transaction valid?

---

## Why Understanding This Flow Matters

**When something breaks:**

You know where to look. If a transaction is stuck, you check:
1. Is it in the database? (PostgreSQL)
2. Is there a message in the queue? (RabbitMQ)
3. Is the worker running? (Kubernetes pods)
4. Are there errors in logs? (Service logs)

**When adding a feature:**

You know which services to modify. If you want to add a transaction fee:
- Transaction Service (calculate fee)
- Wallet Service (deduct fee from sender)
- Database (store fee amount)

**When optimizing:**

You know where bottlenecks are. If transfers are slow:
- Is Wallet Service slow? (database queries)
- Is the queue backing up? (RabbitMQ)
- Are there too many requests? (rate limiting)

**The alternative (not understanding the flow):**

You guess. You check random things. You waste time. You feel lost.

---

## Common Misunderstandings

**"The frontend moves money"**

No. The frontend just makes a request. Services move money.

**"Transaction Service moves money"**

No. Transaction Service creates records and queues work. Wallet Service moves money.

**"RabbitMQ moves money"**

No. RabbitMQ just holds messages. Workers process messages and call Wallet Service.

**"The database moves money"**

Closer, but not quite. The database stores the result. Wallet Service executes the transfer using database transactions.

**The reality:**

Money movement is a collaboration:
- Transaction Service: Creates the intent
- RabbitMQ: Queues the work
- Worker: Coordinates the work
- Wallet Service: Executes the transfer
- Database: Stores the result

No single component does it alone.

---

## What to Do Next

**Try this:**

1. Make a real request (send money in the app)
2. Watch the logs: `kubectl logs -f -n payflow -l app=transaction-service`
3. See the messages: Check RabbitMQ management UI
4. Check the database: Query the transactions table
5. Follow the status changes: PENDING → PROCESSING → COMPLETED

**Then try breaking something:**

1. Stop Wallet Service: `kubectl scale deployment wallet-service --replicas=0 -n payflow`
2. Make a request
3. See what happens (transaction stays PROCESSING)
4. Start Wallet Service again
5. See it complete

**This teaches you:**

- How services depend on each other
- What happens when dependencies fail
- How the system recovers (or doesn't)

---

## Key Takeaways

1. **One request touches multiple services** - Understanding the path is more valuable than knowing every service
2. **State lives in three places** - Database (permanent), Redis (temporary), RabbitMQ (work queue)
3. **Failures happen at boundaries** - Where services communicate is where things break
4. **Async processing is intentional** - Users don't wait, work happens in background
5. **Idempotency prevents duplicates** - Workers check before processing

**The goal isn't to memorize this flow.**

The goal is to understand how to trace any flow. When you encounter a new feature or bug, you'll know how to follow it through the system.

---

*Tracing requests is a skill. Like any skill, it improves with practice. Start with one flow. Understand it completely. Then trace another.*

