# Architecture

## System Design

PayFlow uses microservices architecture to separate concerns: authentication, wallet management, transaction orchestration, and notifications each run as independent services. This allows teams to deploy independently, scale services based on load, and isolate failures. Services communicate via HTTP (synchronous) for user-facing operations and RabbitMQ (asynchronous) for background work.

## Service Map

| Service | Port | Responsibility | Language/Framework |
|---------|------|---------------|-------------------|
| Frontend | 80 | React UI, proxies /api/* to API Gateway | React 18.2.0 |
| API Gateway | 3000 | Single entry point, auth, rate limiting, routing | Express.js 4.18.2 |
| Auth Service | 3004 | User registration, login, JWT tokens, Redis sessions | Express.js 4.18.2 |
| Wallet Service | 3001 | Balance management, atomic money transfers | Express.js 4.18.2 |
| Transaction Service | 3002 | Transaction orchestration, RabbitMQ publishing | Express.js 4.18.2 |
| Notification Service | 3003 | Email/SMS notifications, consumes from RabbitMQ | Express.js 4.18.2 |
| PostgreSQL | 5432 | Primary database for all persistent data | PostgreSQL 15 |
| Redis | 6379 | Sessions, idempotency keys, balance cache | Redis 7 |
| RabbitMQ | 5672/15672 | Async message queue for transaction processing | RabbitMQ 3 |

## Request Flow: Send Money

1. **Browser** → User clicks "Send $100" → Frontend makes `POST /api/transactions`
2. **Frontend** → Nginx proxies `/api/*` → API Gateway:3000
3. **API Gateway** → Validates JWT token → Calls Auth Service `/auth/verify`
4. **API Gateway** → Checks Redis for idempotency key → Prevents duplicate requests
5. **API Gateway** → Validates request (amount, userId) → Forwards to Transaction Service
6. **Transaction Service** → Creates record in PostgreSQL (status: PENDING)
7. **Transaction Service** → Publishes message to RabbitMQ queue `transactions`
8. **Transaction Service** → Returns immediately: `{ id: "TXN-123", status: "PENDING" }`

*— Steps 1–8 are synchronous (milliseconds). Steps 9–17 are asynchronous (happen in background). —*

9. **Worker** (Transaction Service) → Consumes message from RabbitMQ
10. **Worker** → Checks database (idempotency) → Updates status to PROCESSING
11. **Worker** → Calls Wallet Service `POST /wallets/transfer`
12. **Wallet Service** → Starts database transaction → Locks sender wallet → Locks receiver wallet
13. **Wallet Service** → Checks sufficient funds → Debits sender → Credits receiver → Commits
14. **Worker** → Updates transaction status to COMPLETED
15. **Worker** → Publishes notification message to RabbitMQ queue `notifications`
16. **Notification Service** → Consumes message → Sends email to sender and receiver
17. **User** → Receives email: "You sent $100" / "You received $100"

## Communication Patterns

| From | To | Method | Why |
|------|-----|--------|-----|
| Frontend | API Gateway | HTTP REST | User needs immediate response |
| API Gateway | Auth Service | HTTP REST | Verify JWT token synchronously |
| API Gateway | Wallet Service | HTTP REST | Check balance, user waiting |
| API Gateway | Transaction Service | HTTP REST | Create transaction, return ID immediately |
| Transaction Service | Wallet Service | HTTP REST | Transfer money, need confirmation |
| Transaction Service | RabbitMQ | AMQP (publish) | Queue transaction for async processing |
| RabbitMQ | Transaction Service Worker | AMQP (consume) | Process transaction in background |
| Transaction Service | RabbitMQ | AMQP (publish) | Queue notification after completion |
| RabbitMQ | Notification Service | AMQP (consume) | Send email/SMS asynchronously |

> **AMQP** (Advanced Message Queuing Protocol) is the wire protocol RabbitMQ uses — similar to HTTP but for message queues. You'll see it in connection strings like `amqp://payflow:payflow123@rabbitmq:5672`. "Publish" = put a message on the queue. "Consume" = read and process a message from the queue.

## Database Schema

**users** → Stores user accounts, passwords (hashed), roles
- Key columns: `id` (PK), `email` (unique), `password_hash`, `role`
- Foreign keys: None (top-level entity)

**wallets** → Stores user wallet balances
- Key columns: `user_id` (PK, FK → users.id), `balance`, `currency`
- Foreign keys: `user_id` references `users(id)` ON DELETE CASCADE

**transactions** → Stores all money transfer records
- Key columns: `id` (PK), `from_user_id`, `to_user_id`, `amount`, `status`, `created_at`
- Foreign keys: `from_user_id` references `users(id)`, `to_user_id` references `users(id)`
- Status values: PENDING → PROCESSING → COMPLETED or FAILED

**notifications** → Stores notification history
- Key columns: `id` (PK), `user_id`, `type`, `message`, `transaction_id`, `read`
- Foreign keys: `user_id` references `users(id)` ON DELETE CASCADE

**refresh_tokens** → Stores refresh tokens for JWT rotation
- Key columns: `id` (PK), `user_id`, `token`, `expires_at`
- Foreign keys: `user_id` references `users(id)` ON DELETE CASCADE

**audit_logs** → Stores security audit trail
- Key columns: `id` (PK), `user_id`, `action`, `resource`, `ip_address`, `metadata`
- Foreign keys: None (tracks all users, including deleted ones)

## Infrastructure

Illustrations below live under [`docs/assets/`](assets/); the same files are referenced from [INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md) and [terraform/terraform.md](../terraform/terraform.md).

### Reference figures

| Figure | File |
|--------|------|
| Platform / stack overview | `Visuals.png` |
| EKS VPC hub-and-spoke pipeline | `EKS VPC Integration Pipeline-2026-03-30-135753.png` |
| AWS & Azure VPC-style comparison | `AWS and Azure VPC Service-2026-03-30-111526.png` |
| EKS cluster & secrets integration | `AWS EKS Cluster Secrets-2026-03-30-104747.png` |

![PayFlow platform overview](assets/Visuals.png)

![EKS VPC hub-and-spoke integration pipeline](assets/EKS%20VPC%20Integration%20Pipeline-2026-03-30-135753.png)

![AWS and Azure VPC service comparison](assets/AWS%20and%20Azure%20VPC%20Service-2026-03-30-111526.png)

![AWS EKS cluster and secrets flow](assets/AWS%20EKS%20Cluster%20Secrets-2026-03-30-104747.png)

### AWS (Production)

**VPC Layout:**
- Hub VPC (10.0.0.0/16) - Transit Gateway, shared services
- Spoke VPC (10.10.0.0/16) - EKS cluster, application workloads
- Private subnets for EKS nodes, public subnets for NAT Gateway and ALB

**Infrastructure Diagram:**

```
┌─────────────────────────────────────────────────────────────┐
│                    Hub VPC (10.0.0.0/16)                    │
│  ┌──────────────┐         ┌──────────────────┐             │
│  │ Public Subnet│         │ Private Subnet   │             │
│  │ (Bastion)    │         │ (Shared Services)│             │
│  │              │         │                  │             │
│  │  ┌────────┐  │         │  ┌────────────┐ │             │
│  │  │Bastion │  │         │  │ RDS        │ │             │
│  │  │ Host   │  │         │  │ PostgreSQL │ │             │
│  │  └────────┘  │         │  └────────────┘ │             │
│  └──────┬───────┘         │  ┌────────────┐ │             │
│         │                  │  │ ElastiCache│ │             │
│         │                  │  │ Redis      │ │             │
│         │                  │  └────────────┘ │             │
│         │                  │  ┌────────────┐ │             │
│         │                  │  │ Amazon MQ  │ │             │
│         │                  │  │ (RabbitMQ) │ │             │
│         │                  │  └────────────┘ │             │
│         │                  └────────┬─────────┘             │
│         │                          │                        │
│         └──────────┬───────────────┘                        │
│                    │                                        │
│         ┌──────────▼──────────┐                             │
│         │ Transit Gateway    │                             │
│         └──────────┬─────────┘                             │
└────────────────────┼───────────────────────────────────────┘
                     │
                     │ (VPC Attachment)
                     │
┌────────────────────▼───────────────────────────────────────┐
│              EKS VPC (10.10.0.0/16)                         │
│  ┌──────────────┐         ┌──────────────────┐            │
│  │ Public Subnet│         │ Private Subnet    │            │
│  │ (NAT/ALB)    │         │ (EKS Nodes/Pods) │            │
│  │              │         │                  │            │
│  │  ┌────────┐  │         │  ┌────────────┐ │            │
│  │  │ NAT    │  │         │  │ EKS Cluster│ │            │
│  │  │Gateway │  │         │  │            │ │            │
│  │  └────────┘  │         │  │ ┌────────┐ │ │            │
│  │  ┌────────┐  │         │  │ │Frontend│ │ │            │
│  │  │ ALB    │  │         │  │ └────────┘ │ │            │
│  │  └────────┘  │         │  │ ┌────────┐ │ │            │
│  └──────┬───────┘         │  │ │API     │ │ │            │
│         │                  │  │ │Gateway │ │ │            │
│         │                  │  │ └────────┘ │ │            │
│         │                  │  │ ┌────────┐ │ │            │
│         │                  │  │ │Auth    │ │ │            │
│         │                  │  │ │Service │ │ │            │
│         │                  │  │ └────────┘ │ │            │
│         │                  │  │ ┌────────┐ │ │            │
│         │                  │  │ │Wallet  │ │ │            │
│         │                  │  │ │Service │ │ │            │
│         │                  │  │ └────────┘ │ │            │
│         │                  │  │ ┌────────┐ │ │            │
│         │                  │  │ │Transact│ │ │            │
│         │                  │  │ │Service │ │ │            │
│         │                  │  │ └────────┘ │ │            │
│         │                  │  │ ┌────────┐ │ │            │
│         │                  │  │ │Notific │ │ │            │
│         │                  │  │ │Service │ │ │            │
│         │                  │  │ └────────┘ │ │            │
│         │                  │  └────────────┘ │            │
│         │                  │                  │            │
│         └──────────┬───────────────┘                        │
│                    │                                        │
│                    │ (Private Endpoint)                     │
└─────────────────────────────────────────────────────────────┘
```

**EKS Cluster:**
- Kubernetes 1.28+
- Private endpoint only (access via Bastion)
- VPC CNI addon for pod networking
- Node groups: on-demand (critical services) + spot (batch jobs)

**RDS PostgreSQL:**
- Multi-AZ for high availability
- Encrypted at rest (KMS)
- Automated backups (7-day retention)
- Private subnet, accessible only from EKS nodes

**ElastiCache Redis:**
- Cluster mode for high availability
- Session storage and caching

**Amazon MQ (RabbitMQ):**
- Managed RabbitMQ broker
- Dead letter queues configured

**Bastion Host:**
- EC2 instance in public subnet
- SSH access to EKS cluster via kubectl

### Azure (Production)

**AKS Cluster:**
- Kubernetes 1.28+
- Private cluster (access via Bastion)
- Azure CNI for pod networking

**Azure Database for PostgreSQL (Flexible Server):**
- Zone-redundant high availability
- Encrypted at rest
- Private endpoint

**Azure Cache for Redis:**
- Premium tier for persistence
- Session storage

**Azure Service Bus:**
- Message queue alternative to RabbitMQ
- Dead letter queues

### Local (Development)

**docker-compose.yml:**
- All services in single network `payflow-network`
- PostgreSQL:5432, Redis:6379, RabbitMQ:5672/15672
- All app services expose ports to host
- Volumes persist data across restarts

## Why These Technology Choices

**PostgreSQL over MongoDB:** Need ACID transactions for money transfers. Relational model fits user-wallet-transaction relationships. SQL queries for complex reporting.

**RabbitMQ over Kafka:** Simpler setup, sufficient throughput for our scale. Dead letter queues and retries built-in. Management UI for debugging.

**Redis for sessions:** Microsecond latency vs milliseconds for database. Automatic expiration. Simple key-value model fits session storage.

**Express.js:** Node.js ecosystem, same language as frontend. Fast development, large middleware ecosystem. Non-blocking I/O handles concurrent requests.

**Kubernetes:** Industry standard for container orchestration. Auto-scaling, self-healing, rolling updates. Works on all major clouds.

---

**Read next:**
- [`docs/system-flow.md`](system-flow.md) — trace a single money transfer through every layer of this architecture
- [`docs/technology-choices.md`](technology-choices.md) — the full reasoning behind each technology decision
- [`docs/SERVICES.md`](SERVICES.md) — ports, endpoints, and env vars for every service
