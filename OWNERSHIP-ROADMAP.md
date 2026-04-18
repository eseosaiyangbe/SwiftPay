# SwiftPay Ownership Roadmap

This document is our working map for taking ownership of SwiftPay.

SwiftPay started as a cloned public repo, but we are now studying it, renaming it, monitoring it, and gradually making it our own. The goal is not to rush into changes. The goal is to understand the system deeply enough that every change we make improves reliability, observability, security, or learning value.

## Current Status

SwiftPay is running locally with Docker Compose under the new `swiftpay` identity.

Validated local URLs:

```bash
curl -fsS http://localhost:8081
curl -fsS http://localhost:3007/health
curl -fsS http://localhost:3004/health
curl -fsS http://localhost:3001/health
curl -fsS http://localhost:3008/health
curl -fsS http://localhost:3003/health
```

Validated database identity:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -tAc "select current_database(), current_user;"
```

Expected result:

```text
swiftpay|swiftpay
```

Observed by the external DevOps Monitor stack:

```text
swiftpay-frontend
swiftpay-api-gateway
swiftpay-auth-service
swiftpay-wallet-service
swiftpay-transaction-service
swiftpay-notification-service
```

## System Purpose

SwiftPay is a fintech-style digital wallet platform.

It demonstrates:

- User registration and login.
- JWT authentication and refresh tokens.
- Wallet creation.
- Wallet balance display.
- Sending money between users.
- Asynchronous transaction processing.
- RabbitMQ queues, retries, and dead-letter handling.
- PostgreSQL transactions and row locking.
- Redis-backed session/cache/idempotency patterns.
- User notifications.
- Prometheus metrics and health checks.
- Docker Compose and Kubernetes deployment paths.

## Runtime Architecture

```text
Browser
  |
  v
Frontend: React + nginx
  |
  | /api/*
  v
API Gateway
  |
  |-- Auth Service
  |-- Wallet Service
  |-- Transaction Service
  |-- Notification Service

Shared infrastructure:

PostgreSQL  -> persistent system of record
Redis       -> token blacklist, cache, idempotency
RabbitMQ    -> transaction and notification queues
```

## Services

### Frontend

Path:

```text
services/frontend
```

Purpose:

- Presents the user-facing SwiftPay app.
- Serves React through nginx.
- Calls relative `/api/*` paths.
- Lets nginx proxy requests to the API Gateway.

Main screens:

- Login and signup.
- Dashboard.
- Send Money.
- Activity.
- Monitoring.

Main file today:

```text
services/frontend/src/App.js
```

Ownership direction:

- Split the large `App.js` into smaller components.
- Move API client logic into a dedicated module.
- Improve mobile layout and loading states.
- Add notification read/delete actions.
- Add transaction detail view.

### API Gateway

Path:

```text
services/api-gateway
```

Purpose:

- Single backend entry point for the frontend.
- Enforces authentication and authorization.
- Applies rate limits.
- Validates request payloads.
- Routes requests to internal services.
- Exposes gateway health and metrics.

Important routes:

```text
GET  /health
GET  /api/health
GET  /metrics
POST /api/auth/register
POST /api/auth/login
POST /api/auth/refresh
POST /api/auth/logout
GET  /api/auth/me
GET  /api/wallets
GET  /api/wallets/:userId
POST /api/transactions
GET  /api/transactions
GET  /api/transactions/:txnId
GET  /api/notifications/:userId
PUT  /api/notifications/:id/read
GET  /api/metrics
```

Ownership direction:

- Treat this as the policy boundary.
- Keep auth and authorization checks here.
- Add consistent correlation IDs across all proxied calls.
- Keep public errors safe and internal errors logged.

### Auth Service

Path:

```text
services/auth-service
```

Purpose:

- Owns identity.
- Registers users.
- Logs users in.
- Hashes passwords with bcrypt.
- Issues JWT access tokens.
- Stores refresh tokens.
- Blacklists logged-out access tokens in Redis.
- Tracks failed login attempts and account lockout.
- Writes audit logs.

Important routes:

```text
GET  /health
GET  /metrics
POST /auth/register
POST /auth/login
POST /auth/refresh
POST /auth/logout
POST /auth/verify
GET  /auth/me
POST /auth/change-password
```

Ownership direction:

- Keep password and token logic isolated here.
- Move away from frontend `localStorage` token storage later.
- Ensure production secrets are never defaults.
- Add tests for login, logout, refresh, lockout, and password change.

### Wallet Service

Path:

```text
services/wallet-service
```

Purpose:

- Owns wallet balances.
- Creates wallets.
- Reads wallet balances.
- Performs atomic money transfers.
- Uses PostgreSQL transactions and row locks.
- Uses Redis for wallet cache.

Important routes:

```text
GET  /health
GET  /metrics
GET  /wallets
GET  /wallets/:userId
POST /wallets
POST /wallets/transfer
GET  /wallets/:userId/balance
```

Critical money rule:

```text
Only Wallet Service should modify balances.
```

Atomic transfer shape:

```sql
BEGIN;
SELECT ... FOR UPDATE;
UPDATE sender balance;
UPDATE receiver balance;
COMMIT;
```

Ownership direction:

- Treat this as the ledger boundary.
- Add strong transfer tests.
- Keep row-locking behavior explicit and documented.
- Ensure every balance mutation has audit visibility.

### Transaction Service

Path:

```text
services/transaction-service
```

Purpose:

- Accepts transaction requests.
- Creates `PENDING` transaction records.
- Publishes work to RabbitMQ.
- Consumes transaction messages.
- Calls Wallet Service to move money.
- Updates transaction status.
- Publishes notification messages.
- Tracks queue and pending transaction metrics.

Important routes:

```text
GET  /health
GET  /metrics
POST /transactions
GET  /transactions
GET  /transactions/:txnId
GET  /metrics/queue
GET  /admin/dlq
```

Queues:

```text
transactions
transactions.retry
transactions.dlq
notifications
```

Transaction states:

```text
PENDING
PROCESSING
COMPLETED
FAILED
```

Ownership direction:

- Harden idempotency before adding new money features.
- Add a worker-level guard so already completed transactions cannot be processed twice.
- Add tests for retries, failed wallet calls, and DLQ behavior.
- Ensure stuck transactions are visible in our DevOps Monitor UI.

### Notification Service

Path:

```text
services/notification-service
```

Purpose:

- Consumes notification messages from RabbitMQ.
- Stores notifications in PostgreSQL.
- Logs or sends email notifications.
- Supports optional Twilio SMS configuration.
- Lets users retrieve notifications.
- Lets users mark notifications as read.

Important routes:

```text
GET  /health
GET  /metrics
GET  /notifications/:userId
PUT  /notifications/:id/read
GET  /notifications/:userId/stats
POST /notifications/test
```

Ownership direction:

- Connect frontend notification read actions.
- Consider notification delete/archive later.
- Keep user-facing notifications separate from DevOps Monitor alerts.

## Data Model

Core tables:

```text
users
wallets
transactions
notifications
audit_logs
refresh_tokens
user_sessions
```

Important files:

```text
migrations/V1__initial_schema.sql
migrations/V2__add_indexes.sql
migrations/V3__auth_tokens_and_sessions.sql
migrations/V4__add_2fa.sql
```

Table responsibilities:

| Table | Purpose |
|---|---|
| `users` | Identity, email, password hash, role, login metadata |
| `wallets` | Balance and currency per user |
| `transactions` | Money transfer lifecycle |
| `notifications` | User notification inbox |
| `audit_logs` | Security and business audit trail |
| `refresh_tokens` | Refresh token persistence |
| `user_sessions` | Session tracking |

## Money Flow

The core transfer path:

```text
1. User clicks Send Money.
2. Frontend posts to /api/transactions.
3. API Gateway authenticates, validates, and authorizes the request.
4. Transaction Service inserts a PENDING transaction.
5. Transaction Service publishes a RabbitMQ message.
6. User receives "transaction queued" response.
7. Transaction worker consumes the message.
8. Transaction moves to PROCESSING.
9. Worker calls Wallet Service.
10. Wallet Service locks sender and receiver wallets.
11. Wallet Service debits sender and credits receiver in one DB transaction.
12. Transaction moves to COMPLETED or FAILED.
13. Notification messages are published.
14. Notification Service stores notifications.
15. Frontend polling shows updated balance, activity, and notifications.
```

Why this pattern matters:

- The user does not wait for the full money movement.
- Work survives restarts because it is recorded in PostgreSQL and queued in RabbitMQ.
- Wallet Service keeps balance mutation atomic.
- Transaction Service owns orchestration and retries.

## Observability

SwiftPay exposes:

```text
/health
/metrics
```

The external DevOps Monitor stack currently monitors SwiftPay through Docker network aliases:

```text
http://swiftpay-frontend/
http://swiftpay-api-gateway:3000/health
http://swiftpay-auth-service:3004/health
http://swiftpay-wallet-service:3001/health
http://swiftpay-transaction-service:3002/health
http://swiftpay-notification-service:3003/health
```

Important metrics include:

- HTTP request duration.
- HTTP request totals.
- Transaction totals.
- Transaction duration.
- Queue depth.
- Pending transaction count.
- Oldest pending transaction timestamp.
- Pending transaction amount.
- Database pool state.
- Database query errors.
- RabbitMQ publish and consume errors.
- Circuit breaker state and transitions.

Ownership direction:

- Put the serious operational view in DevOps Monitor.
- Keep SwiftPay's own Monitoring tab simple.
- Build dashboards around business symptoms, not only infrastructure symptoms.

High-value alerts:

- SwiftPay component down.
- High probe latency.
- Pending transactions stuck.
- Money stuck in pending state.
- RabbitMQ queue depth high.
- Transaction failure rate high.
- Wallet Service circuit breaker open.
- Database connection pool pressure.

## Deployment Model

### Docker Compose

Local runtime:

```bash
docker compose up -d
```

Fresh reset:

```bash
docker compose down -v
docker compose up -d --build
```

Current host ports:

| Service | Host URL |
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

### Kubernetes

Kubernetes base lives in:

```text
k8s/base
```

It includes:

- Namespace.
- ConfigMap.
- Deployments.
- Services.
- Database migration job.
- Transaction timeout job.
- Network policies.
- Pod disruption budgets.
- Resource quotas.
- Horizontal pod autoscalers.

Local Kubernetes overlay:

```text
k8s/overlays/local
```

Cloud overlays:

```text
k8s/overlays/eks
k8s/overlays/aks
```

Ownership direction:

- Keep Docker Compose working first.
- Then move to local Kubernetes.
- Then connect Kubernetes to DevOps Monitor.
- Then decide what belongs behind Cloudflared.

## Known Gaps And Risks

### 1. Worker-Level Idempotency Needs Hardening

The transaction creation path supports Redis idempotency when an idempotency key is provided.

However, before Wallet Service is called, the worker should explicitly guard against re-processing a transaction that is already `COMPLETED` or already being processed by another worker.

Target fix:

```text
When consuming a transaction message:
- Lock the transaction row.
- If status is COMPLETED, ack and skip.
- If status is PROCESSING and not stale, ack or requeue safely.
- Only PENDING should proceed to wallet transfer.
```

### 2. Docs And Code Need Alignment

Some docs describe older behavior. For example, some sections say Auth Service creates the wallet directly. The current code creates the user in Auth Service, then API Gateway calls Wallet Service to create the wallet.

Target fix:

```text
Update docs after we harden the money flow.
```

### 3. Frontend Is One Large File

`services/frontend/src/App.js` contains the API client, auth screen, app state, dashboard, send form, activity, and monitoring UI.

Target fix:

```text
Split it into components and a dedicated API client.
```

### 4. Token Storage Is Not Fintech-Grade Yet

Frontend stores tokens in `localStorage`.

Target fix:

```text
Later, move toward secure httpOnly cookies or another stronger session model.
```

### 5. Notification Backend Has More Features Than Frontend

Backend supports marking notifications as read, but the frontend does not expose that yet.

Target fix:

```text
Add read/unread actions to the frontend.
```

### 6. Compose Monitoring Profile Is Not Our Primary Monitoring Path

SwiftPay has its own monitoring profile, but we are using the external DevOps Monitor stack.

Target fix:

```text
Keep SwiftPay connected to observability-net and make DevOps Monitor the control plane.
```

## Ownership Phases

### Phase 0: Baseline And Identity

Status: complete first pass.

Completed:

- Renamed PayFlow references to SwiftPay.
- Reset local Docker volumes.
- Recreated the app under the `swiftpay` database/user identity.
- Connected SwiftPay to the external observability network.
- Confirmed all local services are healthy.
- Confirmed DevOps Monitor sees SwiftPay as healthy.

Success criteria:

- No `PayFlow/payflow/PAYFLOW` references remain.
- Docker Compose stack starts cleanly.
- Postgres identity is `swiftpay|swiftpay`.
- Frontend opens at `http://localhost:8081`.

### Phase 1: Stabilize And Document The Money Flow

Status: complete first pass.

Goal:

Make the transaction lifecycle boringly correct.

Work items:

- Add worker-level transaction status guard. Complete first pass.
- Add tests for duplicate message processing. Complete first pass.
- Add Wallet Service transfer tests. Complete first pass.
- Add tests for insufficient funds. Complete first pass.
- Add tests for wallet service failure. Complete first pass.
- Add tests for successful send money flow. Complete first pass.
- Add repeatable Send Money smoke test. Complete first pass.
- Document the exact transaction lifecycle after the code is verified. Complete first pass.

Success criteria:

- Duplicate queued messages cannot move money twice.
- Failed transactions become visible and explainable.
- Tests cover the core money path.

Progress notes:

- Added a transaction row lock in `transaction-service` before Wallet Service is called.
- Only `PENDING` transactions are allowed to proceed to money movement.
- Duplicate messages for `PROCESSING`, `COMPLETED`, or `FAILED` transactions are skipped.
- Verified with a real completed transaction by republishing the same RabbitMQ message and confirming the sender balance did not change.
- Extracted the row-claim logic into a unit-testable `transaction-guard` module.
- Added unit tests for claiming `PENDING`, skipping `PROCESSING`, skipping `COMPLETED`, skipping `FAILED`, and rolling back when the transaction row is missing.
- Added `services/.dockerignore` so local service `node_modules` folders are not sent into Docker build contexts.
- Extracted Wallet Service atomic transfer logic into a unit-testable `wallet-transfer` module.
- Added unit tests for successful debit/credit, insufficient funds rollback, missing wallet rollback, and stable wallet lock ordering.
- Verified a live `$12.34` transfer through the frontend/API Gateway path after rebuilding Wallet Service.
- Extracted Transaction Service completion/failure handling into a unit-testable `transaction-finalizer` module.
- Added tests proving Wallet Service failures mark transactions as `FAILED`, persist the error message, and enqueue a sender failure notification.
- Added tests proving successful claimed transactions become `COMPLETED` and enqueue sender/receiver notifications.
- Verified the real end-to-end Send Money path through API Gateway using two fresh smoke users.
- Added `scripts/smoke-send-money.sh` and `npm run smoke:send-money` so the transfer path can be rechecked after Docker Compose, Kubernetes, or ingress changes.
- Added `docs/send-money-runbook.md` as the canonical money-flow runbook for verification and troubleshooting.
- Fixed Transaction Service so business failures from Wallet Service, such as `Insufficient funds`, do not open the circuit breaker or get masked as service outages.
- Added `scripts/smoke-failed-transaction.sh` and `npm run smoke:failed-transaction` for repeatable failed-transfer testing.

Repeatable smoke test:

```bash
npm run smoke:send-money
```

Override examples:

```bash
BASE_URL=http://localhost:3007/api npm run smoke:send-money
SMOKE_AMOUNT=10.25 npm run smoke:send-money
```

### Phase 2: Improve SwiftPay Observability

Status: complete first pass.

Goal:

Make SwiftPay business health visible in DevOps Monitor.

Work items:

- Add or verify alerts for pending transactions. Complete first pass.
- Add or verify alerts for transaction failure rate. Complete first pass.
- Add or verify alerts for queue depth. Complete first pass.
- Add SwiftPay dashboard panels in DevOps Monitor. Complete first pass.
- Add runbook links for SwiftPay alerts. Complete first pass.

Success criteria:

- We can see if money is stuck.
- We can see if queue processing is broken.
- We can see if Wallet Service is the bottleneck.
- Alerts explain what action to take.

Progress notes:

- Added Prometheus scrape jobs for SwiftPay API Gateway, Auth Service, Wallet Service, Transaction Service, and Notification Service.
- Added SwiftPay recording rules for pending transactions, pending amount, transaction queue depth, transaction failure rate, wallet failure rate, and circuit breaker state.
- Added SwiftPay alert rules for scrape health, stuck pending transfers, money stuck pending, queue depth, transaction failure rate, wallet failure rate, and open circuit breaker.
- Added a DevOps Monitor API route at `/api/apps/swiftpay/business` for dashboard business metrics.
- Added a custom SwiftPay Money Flow section to the DevOps Monitor dashboard.
- Verified all SwiftPay Prometheus targets return `up=1`.
- Verified the DevOps Monitor UI container rebuilt and started healthy.
- Added `docs/observability-runbook.md` as the operational guide for this phase.

### Phase 3: Frontend Ownership

Status: complete first pass.

Goal:

Make the frontend easier to maintain before adding features.

Work items:

- Extract API client. Complete first pass.
- Extract auth screen. Complete first pass.
- Extract dashboard tab. Complete first pass.
- Extract send money tab. Complete first pass.
- Extract activity tab. Complete first pass.
- Extract monitoring tab. Complete first pass.
- Add notification read action. Complete first pass.
- Add notification delete action. Complete first pass.
- Add loading and empty states. Complete first pass.

Success criteria:

- Frontend behavior stays the same.
- Code is easier to reason about.
- New UI changes are safer to make.

Progress notes:

- Reduced `services/frontend/src/App.js` from one large all-in-one file into a coordinator component.
- Moved API URL handling, auth token storage, request retry, and service methods into `services/frontend/src/lib/api-client.js`.
- Moved session timeout constants into `services/frontend/src/lib/session-config.js`.
- Moved transaction sorting and relative-age helpers into `services/frontend/src/lib/transaction-utils.js`.
- Extracted `LoginPage`, `DashboardTab`, `SendMoneyTab`, `ActivityTab`, and `MonitoringTab`.
- Verified the React production build after each extraction.
- Added frontend support for the existing notification read API.
- Added dashboard unread count, per-notification read state, and a saving state for "Mark read".
- Added owner-scoped notification deletion in Notification Service and API Gateway.
- Added dashboard delete action with a per-notification deleting state.
- Added first-pass loading and empty states for notifications, monitoring metrics, and missing Send Money recipients.
- Verified the notification read flow through API Gateway with a real completed transaction notification.
- Added `scripts/smoke-notifications.sh` and `npm run smoke:notifications` for repeatable notification read/delete verification.

### Phase 4: Security And Session Hardening

Status: in progress, backend first pass complete.

Goal:

Move closer to fintech-grade security practices.

Work items:

- Review JWT and refresh token flow. Complete first pass.
- Replace or reduce frontend `localStorage` token exposure. Complete first pass.
- Review CORS configuration. Complete first pass.
- Review secrets strategy. Complete first pass.
- Ensure default credentials cannot run in production. Complete first pass for JWT secrets.
- Add auth-related tests. Complete first pass.

Success criteria:

- Production mode refuses weak secrets.
- Token handling is safer.
- Auth behavior is documented and tested.

Progress notes:

- Added production JWT secret guards in Auth Service and API Gateway auth middleware.
- Added weak/default JWT secret rejection for production mode.
- Added `jti` claims to generated access and refresh tokens so newly issued tokens are unique.
- Added refresh token rotation in Auth Service so used refresh tokens cannot be replayed.
- Hardened API Gateway CORS parsing for comma-separated trusted origins.
- Kept empty `CORS_ORIGIN` development-friendly for Docker Compose, while rejecting missing or wildcard CORS origins in production.
- Updated `.env.example` to use `http://localhost:8081` instead of `*`.
- Added `scripts/smoke-auth-security.sh` and `npm run smoke:auth-security`.
- Added `docs/security-session-runbook.md` as the operational guide for this phase.
- Moved frontend tokens and user profile from `localStorage` to `sessionStorage`.
- Added frontend startup cleanup for legacy `localStorage` token values.

Remaining work:

- Move token handling to HTTP-only cookies or a backend-for-frontend pattern.
- Add deeper automated tests around account lockout, password change, and refresh-token reuse.

### Phase 5: Kubernetes Ownership

Goal:

Move from Docker Compose to Kubernetes without losing observability.

Work items:

- Deploy SwiftPay to local Kubernetes.
- Validate service DNS.
- Validate readiness/liveness probes.
- Validate migrations.
- Validate network policies.
- Connect Kubernetes SwiftPay targets to DevOps Monitor.
- Prepare Cloudflared entry path.

Success criteria:

- SwiftPay runs in Kubernetes.
- DevOps Monitor can observe it.
- Frontend and API paths work through ingress.
- Internal services remain private.

### Phase 6: Product Features

Goal:

Only add user-facing fintech features after the core system is safe.

Possible features:

- Transaction detail page.
- Notification read/unread UI.
- Payment confirmation modal.
- User profile page.
- Export transaction history.
- Better admin/ops view.
- WebSocket or SSE notifications.

Success criteria:

- New features do not weaken money safety.
- Observability improves with each feature.
- Documentation stays current.

## Command Reference

Start SwiftPay:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
docker compose up -d
```

Rebuild SwiftPay:

```bash
docker compose up -d --build
```

Fresh local reset:

```bash
docker compose down -v
docker compose up -d --build
```

Check containers:

```bash
docker compose ps
```

Check service health:

```bash
curl -fsS http://localhost:3007/health
curl -fsS http://localhost:3004/health
curl -fsS http://localhost:3001/health
curl -fsS http://localhost:3008/health
curl -fsS http://localhost:3003/health
curl -I http://localhost:8081
```

Check database identity:

```bash
docker compose exec -T postgres psql -U swiftpay -d swiftpay -tAc "select current_database(), current_user;"
```

Check observability probes from Prometheus:

```bash
curl -fsS 'http://localhost:9090/api/v1/query?query=probe_success{job="blackbox-http",app="swiftpay"}' | python3 -m json.tool
```

Check DevOps Monitor SwiftPay overview:

```bash
curl -fsS http://localhost:4000/api/apps/swiftpay/overview | python3 -m json.tool
```

## Decision Log

### 2026-04-16: Rename And Reset

Decision:

Rename PayFlow references to SwiftPay and reset the local database.

Reason:

The folder had already been renamed, and the runtime identity needed to match the project identity.

Result:

- Text references were renamed.
- Files with `payflow` in their names were renamed.
- Local volumes were deleted.
- Fresh `swiftpay` database/user were created.
- Services started healthy.

### 2026-04-16: External DevOps Monitor Is The Control Plane

Decision:

Use the external `Obervability-Stack` DevOps Monitor UI as the main operational view instead of relying on SwiftPay's built-in monitoring profile.

Reason:

We are building one observability control plane for OpenSIS, SwiftPay, MemFlip, and FoodPulse.

Result:

SwiftPay stays observable through Docker aliases and later Kubernetes service names.
