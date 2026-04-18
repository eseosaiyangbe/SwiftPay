# Services

> **How to read this:** Each service section starts with *why it exists as a separate service*, then gives the technical reference (ports, endpoints, env vars). Read the "why" before diving into the tables — it's the context that makes the code make sense.

---

## API Gateway
**Port:** 3000

**Why does this exist as a separate service?**
The frontend only needs to know one address — `api.swiftpay.local` — regardless of how many backend services there are or how they're deployed. The gateway is the single door. It handles authentication checks, rate limiting, and request routing in one place so every backend service doesn't need to implement those things itself. In production systems (Stripe, Square, Uber) this pattern is called an API Gateway and it's how you prevent a single slow or broken service from being directly exposed to users.

**Purpose:** Single entry point for all client requests. Handles authentication, rate limiting, request validation, and routes to appropriate microservices.

### Endpoints

| Method | Path | Auth Required | What it does |
|--------|------|--------------|-------------|
| GET | /health | No | Returns API Gateway health status |
| GET | /api/health | No | Same as /health |
| GET | /metrics | No | Prometheus metrics endpoint |
| POST | /api/auth/register | No | Register new user (rate limited: 50 req/15min) |
| POST | /api/auth/login | No | User login, returns JWT token (rate limited: 50 req/15min) |
| POST | /api/auth/refresh | No | Refresh access token using refresh token |
| POST | /api/auth/logout | Yes | Logout user, blacklist token |
| GET | /api/auth/me | Yes | Get current user profile |
| GET | /api/wallets | Yes | List all wallets (admin only) |
| GET | /api/wallets/:userId | Yes | Get wallet by user ID (owner or admin) |
| POST | /api/transactions | Yes | Create new transaction (rate limited: 10 req/min) |
| GET | /api/transactions | Yes | List transactions (filtered by userId, status) |
| GET | /api/transactions/:txnId | Yes | Get transaction by ID (owner or admin) |
| GET | /api/notifications/:userId | Yes | Get notifications for user (owner or admin) |
| GET | /api/admin/metrics | Yes (admin) | Get health status of all services |
| GET | /api/metrics | No | Public metrics (limited info) |

### Routes to Services

- `/api/auth/*` → `http://auth-service:3004/auth/*`
- `/api/wallets/*` → `http://wallet-service:3001/wallets/*`
- `/api/transactions/*` → `http://transaction-service:3002/transactions/*`
- `/api/notifications/*` → `http://notification-service:3003/notifications/*`

### Environment Variables

| Variable | Required | Example | Purpose |
|----------|----------|---------|---------|
| PORT | No | 3000 | API Gateway port |
| AUTH_SERVICE_URL | No | http://auth-service:3004 | Auth service URL |
| WALLET_SERVICE_URL | No | http://wallet-service:3001 | Wallet service URL |
| TRANSACTION_SERVICE_URL | No | http://transaction-service:3002 | Transaction service URL |
| NOTIFICATION_SERVICE_URL | No | http://notification-service:3003 | Notification service URL |
| CORS_ORIGIN | No | * | Allowed CORS origins |
| NODE_ENV | No | development | Environment (development/production) |

---

## Auth Service
**Port:** 3004

**Why does this exist as a separate service?**
Authentication is the most sensitive part of the system — it touches passwords, tokens, and identity. Keeping it isolated means a bug in the wallet service cannot accidentally expose auth logic, and you can scale or harden auth independently. It also owns the user table and token blacklist, making it the single source of truth for "is this person who they say they are?" Every other service trusts the gateway's auth check, but the gateway always calls *this* service to verify. This is why the JWT secret only needs to live in one place.

**Purpose:** User authentication, JWT token management, password hashing, session management with Redis.

### Endpoints

| Method | Path | Auth Required | What it does |
|--------|------|--------------|-------------|
| GET | /health | No | Health check (PostgreSQL + Redis) |
| GET | /metrics | No | Prometheus metrics |
| POST | /auth/register | No | Register new user, create wallet, return JWT |
| POST | /auth/login | No | Authenticate user, return JWT + refresh token |
| POST | /auth/refresh | No | Generate new access token from refresh token |
| POST | /auth/logout | Yes | Blacklist token in Redis, delete refresh tokens |
| POST | /auth/verify | No | Verify JWT token (used by API Gateway) |
| GET | /auth/me | Yes | Get current user profile |
| POST | /auth/change-password | Yes | Change user password |

### Key Logic

**JWT Generation:**
- Access token: Signed with `JWT_SECRET`, expires in 24h (configurable)
- Refresh token: Signed with same secret, expires in 7 days
- Payload: `{ userId, email, role }` for access, `{ userId, type: 'refresh' }` for refresh

**Redis Session Storage:**
- Token blacklist: `blacklist:{token}` with TTL matching token expiration
- Checked on every `/auth/verify` request
- Prevents use of logged-out tokens

**Password Security:**
- bcrypt with 12 rounds
- Account locks after 5 failed attempts (30-minute lockout)
- Failed attempt counter resets on successful login

**Wallet Creation:**
- Automatically creates wallet with $1000.00 balance on user registration
- Wallet created in same database transaction as user

### Environment Variables

| Variable | Required | Example | Purpose |
|----------|----------|---------|---------|
| PORT | No | 3004 | Auth service port |
| DB_HOST | No | postgres | PostgreSQL host |
| DB_PORT | No | 5432 | PostgreSQL port |
| DB_NAME | No | swiftpay | Database name |
| DB_USER | No | swiftpay | Database user |
| DB_PASSWORD | No | swiftpay123 | Database password |
| REDIS_URL | No | redis://redis:6379 | Redis connection URL |
| JWT_SECRET | Yes | your-secret-key | Secret for signing JWT tokens |
| JWT_EXPIRES_IN | No | 24h | Access token expiration |

---

## Wallet Service
**Port:** 3001

**Why does this exist as a separate service?**
Money movement is the most dangerous operation in a payment system — if two transfers happen simultaneously to the same wallet, you can double-spend or corrupt balances. The wallet service owns this problem entirely: it holds the database row locks, runs the atomic SQL transaction, and is the *only* place in the system that can change a balance. By isolating it, the transaction service can call it over HTTP and trust that the wallet service will either complete the transfer correctly or reject it — never silently corrupt data. This mirrors how fintech companies like Stripe separate "ledger" logic from "payment orchestration."

**Purpose:** Wallet balance management, atomic money transfers using PostgreSQL transactions with row locking.

### Endpoints

| Method | Path | Auth Required | What it does |
|--------|------|--------------|-------------|
| GET | /health | No | Health check (PostgreSQL + Redis) |
| GET | /metrics | No | Prometheus metrics |
| GET | /wallets | No | List all wallets (internal use) |
| GET | /wallets/:userId | No | Get wallet by user ID |
| POST | /wallets | No | Create wallet (called by Auth Service) |
| POST | /wallets/transfer | No | Transfer money between wallets (internal, called by Transaction Service) |
| GET | /wallets/:userId/balance | No | Get balance only (cached in Redis) |

### Key Logic

**Wallet Creation:**
- Created automatically on user registration (via Auth Service)
- Default balance: $1000.00
- Currency: USD (default)

**Balance Checking:**
- Redis cache: `wallet:{userId}` (60s TTL), `wallet:{userId}:balance` (10s TTL)
- Cache miss → Query PostgreSQL → Store in Redis
- Cache hit rate tracked in Prometheus

**Money Transfer (Atomic):**
```sql
BEGIN;
  SELECT balance FROM wallets WHERE user_id = $1 FOR UPDATE;  -- Lock sender
  SELECT balance FROM wallets WHERE user_id = $2 FOR UPDATE;  -- Lock receiver
  -- Check sufficient funds
  UPDATE wallets SET balance = balance - $amount WHERE user_id = $1;  -- Debit
  UPDATE wallets SET balance = balance + $amount WHERE user_id = $2;  -- Credit
COMMIT;
```
- Row locks (`FOR UPDATE`) prevent concurrent modifications
- Either both updates succeed (COMMIT) or both fail (ROLLBACK)
- Cache invalidated after transfer: `wallet:{fromUserId}`, `wallet:{toUserId}`, `wallets:all`

**Double-Spend Prevention:**
- Database transactions ensure atomicity
- Row locking prevents race conditions
- Sufficient funds check before transfer

### Environment Variables

| Variable | Required | Example | Purpose |
|----------|----------|---------|---------|
| PORT | No | 3001 | Wallet service port |
| DB_HOST | No | postgres | PostgreSQL host |
| DB_PORT | No | 5432 | PostgreSQL port |
| DB_NAME | No | swiftpay | Database name |
| DB_USER | No | swiftpay | Database user |
| DB_PASSWORD | No | swiftpay123 | Database password |
| REDIS_URL | No | redis://redis:6379 | Redis connection URL |

---

## Transaction Service
**Port:** 3002

**Why does this exist as a separate service?**
Sending money is not instant — it involves checking balances, locking funds, debiting, crediting, and notifying. If you did all of that synchronously in a single HTTP request and anything timed out, the user would see an error even though their money might have moved. The transaction service solves this by separating *accepting the request* (fast, synchronous) from *processing it* (slower, asynchronous via RabbitMQ). The user gets an immediate "transaction received" response; the actual money movement happens in the background. This is how Venmo, Cash App, and most payment systems work — the UI confirms fast, processing happens reliably in the background. Idempotency keys ensure that if the user hits "Send" twice by accident, only one transfer goes through.

**Purpose:** Transaction orchestration, async processing via RabbitMQ, idempotency, circuit breakers.

### Endpoints

| Method | Path | Auth Required | What it does |
|--------|------|--------------|-------------|
| GET | /health | No | Health check (PostgreSQL + RabbitMQ + circuit breaker state) |
| GET | /metrics | No | Prometheus metrics |
| POST | /transactions | No | Create transaction, publish to RabbitMQ, return immediately |
| GET | /transactions | No | List transactions (filtered by userId, status, limit) |
| GET | /transactions/:txnId | No | Get transaction by ID |
| GET | /metrics/queue | No | Queue depth and transaction status counts |
| GET | /admin/dlq | No | Dead letter queue status |

### Key Logic

**Transaction States:**
- PENDING: Created, queued in RabbitMQ, not processed yet
- PROCESSING: Worker picked up message, calling Wallet Service
- COMPLETED: Money transferred successfully
- FAILED: Transfer failed or timeout

**Idempotency:**
- API level: Redis key `idempotency:{userId}:create-transaction:{params}` (24h TTL)
- Worker level: Database check before processing (if status is PROCESSING or COMPLETED, skip)
- Prevents duplicate charges on retries

**Message Queue:**
- Publishes to: `transactions` queue (durable, persistent)
- Message payload: `{ id, from_user_id, to_user_id, amount }`
- Dead letter queue: `transactions.dlq` (after 3 retries)
- Retry queue: `transactions.retry` (30s TTL, then back to main queue)

**Circuit Breaker:**
- Protects Wallet Service calls
- Opens after 50% error rate
- Half-open after 30s timeout
- Prevents cascading failures

**Transaction Processing Flow:**
1. Create record in PostgreSQL (status: PENDING)
2. Publish to RabbitMQ
3. Return to user immediately
4. Worker consumes message
5. Update status: PROCESSING
6. Call Wallet Service `/wallets/transfer` (with circuit breaker)
7. Update status: COMPLETED or FAILED
8. Publish notification to `notifications` queue

### Message Queue
- **Publishes to:** `transactions` queue
- **Message payload:** `{ id: "TXN-123", from_user_id: "user-1", to_user_id: "user-2", amount: 100.00 }`
- **Consumes from:** `transactions` queue (worker)
- **Dead Letter Queue:** `transactions.dlq` (permanently failed messages)

### Environment Variables

| Variable | Required | Example | Purpose |
|----------|----------|---------|---------|
| PORT | No | 3002 | Transaction service port |
| DB_HOST | No | postgres | PostgreSQL host |
| DB_PORT | No | 5432 | PostgreSQL port |
| DB_NAME | No | swiftpay | Database name |
| DB_USER | No | swiftpay | Database user |
| DB_PASSWORD | No | swiftpay123 | Database password |
| RABBITMQ_URL | No | amqp://swiftpay:swiftpay123@rabbitmq:5672 | RabbitMQ connection URL |
| REDIS_URL | No | redis://redis:6379 | Redis connection URL (for idempotency) |
| WALLET_SERVICE_URL | No | http://wallet-service:3001 | Wallet service URL |

---

## Notification Service
**Port:** 3003

**Why does this exist as a separate service?**
Sending an email or SMS is a side effect — it should never block or fail a money transfer. If the notification service is down or the SMTP server is slow, the transaction should still complete. By consuming from a RabbitMQ queue instead of being called directly, the notification service is completely decoupled: the transaction service publishes "transaction completed" and forgets about it. The notification service picks it up when it's ready. This also makes it easy to add new notification channels (push notifications, Slack) without touching any other service. It's a classic example of the "fire and forget" event-driven pattern.

**Purpose:** Consumes notification messages from RabbitMQ, sends email/SMS notifications, stores notification history.

### Endpoints

| Method | Path | Auth Required | What it does |
|--------|------|--------------|-------------|
| GET | /health | No | Health check (PostgreSQL + RabbitMQ + email/SMS config) |
| GET | /metrics | No | Prometheus metrics |
| GET | /notifications/:userId | No | Get notifications for user (last 50) |
| PUT | /notifications/:id/read | No | Mark notification as read |
| GET | /notifications/:userId/stats | No | Notification statistics (total, unread, by type) |
| POST | /notifications/test | No | Manual notification trigger (testing) |

### Key Logic

**Message Consumption:**
- Consumes from: `notifications` queue (durable)
- Message payload: `{ userId, type, message, transactionId, amount, otherParty }`
- Types: `TRANSACTION_COMPLETED`, `TRANSACTION_RECEIVED`, `TRANSACTION_FAILED`

**Email Sending:**
- Uses nodemailer with SMTP (Gmail, SendGrid, etc.)
- HTML templates for transaction notifications
- Falls back to logging if SMTP not configured
- Tracks send duration in Prometheus

**SMS Sending (Optional):**
- Uses Twilio if `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN` configured
- Falls back to logging if not configured
- Transaction alerts only

**Notification Storage:**
- All notifications stored in PostgreSQL `notifications` table
- Tracks: `user_id`, `type`, `message`, `transaction_id`, `read` status
- Indexed on `user_id` and `created_at` for fast queries

### Message Queue
- **Consumes from:** `notifications` queue
- **Message payload:** `{ userId: "user-1", type: "TRANSACTION_COMPLETED", message: "You sent $100", transactionId: "TXN-123", amount: 100, otherParty: "user-2" }`

### Environment Variables

| Variable | Required | Example | Purpose |
|----------|----------|---------|---------|
| PORT | No | 3003 | Notification service port |
| DB_HOST | No | postgres | PostgreSQL host |
| DB_PORT | No | 5432 | PostgreSQL port |
| DB_NAME | No | swiftpay | Database name |
| DB_USER | No | swiftpay | Database user |
| DB_PASSWORD | No | swiftpay123 | Database password |
| RABBITMQ_URL | No | amqp://swiftpay:swiftpay123@rabbitmq:5672 | RabbitMQ connection URL |
| SMTP_HOST | No | smtp.gmail.com | SMTP server host |
| SMTP_PORT | No | 587 | SMTP server port |
| SMTP_USER | No | noreply@swiftpay.com | SMTP username |
| SMTP_PASSWORD | No | password | SMTP password |
| TWILIO_ACCOUNT_SID | No | AC... | Twilio account SID (optional) |
| TWILIO_AUTH_TOKEN | No | token | Twilio auth token (optional) |
| TWILIO_PHONE_NUMBER | No | +1234567890 | Twilio phone number (optional) |

---

**Read next:**
- Each service has its own `README.md` with the most interesting code to read, how to run it locally, and questions to test your understanding — open `services/<name>/README.md`
- [`docs/tracing-a-single-request.md`](tracing-a-single-request.md) — see how all these services work together on a live request
- [`docs/microk8s-deployment.md`](microk8s-deployment.md) — deploy them all to Kubernetes

