# SwiftPay Platform-Agnostic Design

> **Purpose**: This document captures the architectural design principles of SwiftPay, independent of any specific platform (Kubernetes, AWS ECS, GCP Cloud Run, etc.). Use this to understand **why** we made each design choice, not **how** to implement it.

---

## Table of Contents

1. [Platform Comparison Diagram](#platform-comparison-diagram)
2. [Workload Classification](#workload-classification)
3. [Network Architecture](#network-architecture)
4. [Ingress Strategy](#ingress-strategy)
5. [Failure Expectations & Resilience](#failure-expectations--resilience)
6. [Data Persistence Strategy](#data-persistence-strategy)
7. [Resource Patterns](#resource-patterns)
8. [Security Boundaries](#security-boundaries)
9. [Scaling Philosophy](#scaling-philosophy)
10. [Operational Concerns](#operational-concerns)
11. [Design Principles Summary](#design-principles-summary)

---

## Platform Comparison Diagram

> **Key Insight**: Same architecture, different boxes. The logical design remains constant across platforms.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    SAME LOGICAL ARCHITECTURE                                         │
│                                                                                                      │
│                                         USER BROWSER                                                 │
│                                            (HTTPS)                                                   │
└──────────────────────────────────────────┬──────────────────────────────────────────────────────────┘
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    │                                              │
       ┌────────────▼────────────┐                   ┌────────────▼────────────┐
       │    MICROK8S (Current)   │                   │      AWS (Future)       │
       └─────────────────────────┘                   └─────────────────────────┘

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  LAYER 1: INGRESS (TLS Termination)      │   │  LAYER 1: INGRESS (TLS Termination)      │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  Nginx Ingress Controller                │   │  Application Load Balancer (ALB)         │
│  ├─ TLS Certificate (self-signed/LE)     │   │  ├─ TLS Certificate (ACM)                │
│  ├─ Routes: www.swiftpay.local            │   │  ├─ Routes: www.swiftpay.com              │
│  ├─ Rate Limiting: 100 req/min           │   │  ├─ Rate Limiting: AWS WAF               │
│  └─ Backend: frontend:80, api-gateway:80 │   │  └─ Target Groups: frontend, api-gateway │
│                                          │   │                                          │
│  Implementation: Kubernetes Ingress      │   │  Implementation: AWS ALB + Route53       │
│                                          │   │                                          │
└────────────────┬─────────────────────────┘   └────────────────┬─────────────────────────┘
                 │                                               │
       ┌─────────┴─────────┐                         ┌──────────┴──────────┐
       │                   │                         │                     │
       ▼                   ▼                         ▼                     ▼

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  LAYER 2: STATELESS SERVICES (Frontend)  │   │  LAYER 2: STATELESS SERVICES (Frontend)  │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  Frontend (React + Nginx)                │   │  Frontend (React + Nginx)                │
│  ├─ Deployment: 2 replicas               │   │  ├─ ECS Service: 2 tasks                 │
│  ├─ Service: ClusterIP (port 80)         │   │  ├─ Target Group: Port 80                │
│  ├─ HPA: 2-6 replicas (CPU > 70%)        │   │  ├─ Auto Scaling: 2-6 tasks (CPU > 70%)  │
│  ├─ Resources: 50m CPU, 64Mi RAM         │   │  ├─ Task Size: 0.25 vCPU, 512 MB         │
│  └─ Health Check: HTTP /                 │   │  └─ Health Check: HTTP / on port 80      │
│                                          │   │                                          │
│  Implementation: Kubernetes Deployment   │   │  Implementation: ECS Fargate Service     │
│                                          │   │                                          │
└────────────────┬─────────────────────────┘   └────────────────┬─────────────────────────┘
                 │                                               │
                 │                                               │

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  LAYER 3: API GATEWAY (Single Entry)     │   │  LAYER 3: API GATEWAY (Single Entry)     │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  API Gateway (Express.js)                │   │  API Gateway (Express.js)                │
│  ├─ Deployment: 2 replicas               │   │  ├─ ECS Service: 2 tasks                 │
│  ├─ Service: LoadBalancer (port 80)      │   │  ├─ Target Group: Port 3000              │
│  ├─ HPA: 2-10 replicas (CPU > 70%)       │   │  ├─ Auto Scaling: 2-10 tasks (CPU > 70%) │
│  ├─ Resources: 250m CPU, 256Mi RAM       │   │  ├─ Task Size: 0.5 vCPU, 1 GB            │
│  ├─ Auth: JWT verification               │   │  ├─ Auth: JWT verification               │
│  ├─ Rate Limiting: Redis-backed          │   │  ├─ Rate Limiting: ElastiCache-backed    │
│  └─ Routes to: Auth, Wallet, Txn, Notify │   │  └─ Routes to: Auth, Wallet, Txn, Notify │
│                                          │   │                                          │
│  Implementation: Kubernetes Deployment   │   │  Implementation: ECS Fargate Service     │
│                                          │   │                                          │
└────────────┬─────────────────────────────┘   └────────────┬─────────────────────────────┘
             │                                               │
    ┌────────┴────────┐                           ┌─────────┴────────┐
    │                 │                           │                  │
    ▼                 ▼                           ▼                  ▼

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  LAYER 4: BACKEND MICROSERVICES          │   │  LAYER 4: BACKEND MICROSERVICES          │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  Auth Service (Node.js)                  │   │  Auth Service (Node.js)                  │
│  ├─ Deployment: 2 replicas               │   │  ├─ ECS Service: 2 tasks                 │
│  ├─ Service: ClusterIP (port 3004)       │   │  ├─ Service Discovery: Cloud Map         │
│  ├─ HPA: 2-8 replicas                    │   │  ├─ Auto Scaling: 2-8 tasks              │
│  ├─ Resources: 250m CPU, 256Mi RAM       │   │  ├─ Task Size: 0.5 vCPU, 1 GB            │
│  └─ Depends on: PostgreSQL, Redis        │   │  └─ Depends on: RDS, ElastiCache         │
│                                          │   │                                          │
│  Wallet Service (Node.js)                │   │  Wallet Service (Node.js)                │
│  ├─ Deployment: 2 replicas               │   │  ├─ ECS Service: 2 tasks                 │
│  ├─ Service: ClusterIP (port 3001)       │   │  ├─ Service Discovery: Cloud Map         │
│  ├─ HPA: 2-8 replicas                    │   │  ├─ Auto Scaling: 2-8 tasks              │
│  ├─ Resources: 250m CPU, 256Mi RAM       │   │  ├─ Task Size: 0.5 vCPU, 1 GB            │
│  └─ Depends on: PostgreSQL, Redis        │   │  └─ Depends on: RDS, ElastiCache         │
│                                          │   │                                          │
│  Transaction Service (Node.js)           │   │  Transaction Service (Node.js)           │
│  ├─ Deployment: 3 replicas               │   │  ├─ ECS Service: 3 tasks                 │
│  ├─ Service: ClusterIP (port 3002)       │   │  ├─ Service Discovery: Cloud Map         │
│  ├─ HPA: 3-10 replicas                   │   │  ├─ Auto Scaling: 3-10 tasks             │
│  ├─ Resources: 250m CPU, 256Mi RAM       │   │  ├─ Task Size: 0.5 vCPU, 1 GB            │
│  └─ Depends on: PostgreSQL, RabbitMQ     │   │  └─ Depends on: RDS, Amazon MQ           │
│                                          │   │                                          │
│  Notification Service (Node.js)          │   │  Notification Service (Node.js)          │
│  ├─ Deployment: 2 replicas               │   │  ├─ ECS Service: 2 tasks                 │
│  ├─ Service: ClusterIP (port 3003)       │   │  ├─ Service Discovery: Cloud Map         │
│  ├─ HPA: 2-6 replicas                    │   │  ├─ Auto Scaling: 2-6 tasks              │
│  ├─ Resources: 250m CPU, 256Mi RAM       │   │  ├─ Task Size: 0.5 vCPU, 1 GB            │
│  └─ Depends on: PostgreSQL, RabbitMQ     │   │  └─ Depends on: RDS, Amazon MQ           │
│                                          │   │                                          │
│  Implementation: Kubernetes Deployments  │   │  Implementation: ECS Fargate Services    │
│                                          │   │                                          │
└────────────┬─────────────────────────────┘   └────────────┬─────────────────────────────┘
             │                                               │
    ┌────────┴────────┐                           ┌─────────┴────────┐
    │                 │                           │                  │
    ▼                 ▼                           ▼                  ▼

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  LAYER 5: STATEFUL INFRASTRUCTURE        │   │  LAYER 5: STATEFUL INFRASTRUCTURE        │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  PostgreSQL (Database)                   │   │  RDS for PostgreSQL (Managed)            │
│  ├─ StatefulSet: 1 replica               │   │  ├─ Instance Type: db.t3.small           │
│  ├─ Service: Headless (port 5432)        │   │  ├─ Multi-AZ: Enabled (high availability)│
│  ├─ Storage: PVC 10GB (hostPath)         │   │  ├─ Storage: 20GB GP3 SSD (auto-scaling) │
│  ├─ Resources: 100m CPU, 256Mi RAM       │   │  ├─ Backup: Automated daily backups      │
│  ├─ Backup: Manual (pg_dump)             │   │  ├─ Encryption: At rest (KMS)            │
│  └─ Data: users, wallets, transactions   │   │  └─ Data: users, wallets, transactions   │
│                                          │   │                                          │
│  Implementation: Kubernetes StatefulSet  │   │  Implementation: AWS RDS                 │
│                                          │   │                                          │
│  Redis (Cache)                           │   │  ElastiCache for Redis (Managed)         │
│  ├─ Deployment: 1 replica                │   │  ├─ Node Type: cache.t3.micro            │
│  ├─ Service: ClusterIP (port 6379)       │   │  ├─ Cluster Mode: Disabled (single node) │
│  ├─ Storage: PVC 1GB (optional)          │   │  ├─ Persistence: AOF enabled             │
│  ├─ Resources: 50m CPU, 128Mi RAM        │   │  ├─ Backup: Manual snapshots             │
│  ├─ Persistence: AOF (append-only)       │   │  ├─ Encryption: At rest and in transit   │
│  └─ Data: cache, sessions, idempotency   │   │  └─ Data: cache, sessions, idempotency   │
│                                          │   │                                          │
│  Implementation: Kubernetes Deployment   │   │  Implementation: AWS ElastiCache         │
│                                          │   │                                          │
│  RabbitMQ (Message Queue)                │   │  Amazon MQ for RabbitMQ (Managed)        │
│  ├─ Deployment: 1 replica                │   │  ├─ Broker Type: mq.t3.micro             │
│  ├─ Service: ClusterIP (5672, 15672)     │   │  ├─ Deployment Mode: Single instance     │
│  ├─ Storage: None (messages in memory)   │   │  ├─ Storage: EBS-backed (durable)        │
│  ├─ Resources: Default                   │   │  ├─ Backup: Automated                    │
│  ├─ Durable Queues: Enabled              │   │  ├─ Encryption: At rest (KMS)            │
│  └─ Data: transaction, notification msgs │   │  └─ Data: transaction, notification msgs │
│                                          │   │                                          │
│  Implementation: Kubernetes Deployment   │   │  Implementation: AWS Amazon MQ           │
│                                          │   │                                          │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  NETWORK SECURITY (Zero Trust)           │   │  NETWORK SECURITY (Zero Trust)           │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  NetworkPolicies:                        │   │  Security Groups:                        │
│  ├─ Default Deny All                     │   │  ├─ Default Deny All                     │
│  ├─ Allow: Ingress → Frontend            │   │  ├─ Allow: ALB → Frontend (port 80)      │
│  ├─ Allow: Ingress → API Gateway         │   │  ├─ Allow: ALB → API Gateway (port 3000) │
│  ├─ Allow: API Gateway → Backends        │   │  ├─ Allow: API Gateway → Backends        │
│  ├─ Allow: Backends → PostgreSQL         │   │  ├─ Allow: ECS Tasks → RDS (port 5432)   │
│  ├─ Allow: Backends → Redis              │   │  ├─ Allow: ECS Tasks → ElastiCache       │
│  ├─ Allow: Backends → RabbitMQ           │   │  ├─ Allow: ECS Tasks → Amazon MQ         │
│  └─ Allow: All → DNS (port 53)           │   │  └─ VPC Endpoints: Private connectivity  │
│                                          │   │                                          │
│  Implementation: Kubernetes Network      │   │  Implementation: AWS Security Groups +   │
│                  Policies                │   │                  Network ACLs            │
│                                          │   │                                          │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  MONITORING & OBSERVABILITY              │   │  MONITORING & OBSERVABILITY              │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  Prometheus (Metrics)                    │   │  CloudWatch Metrics                      │
│  ├─ Scrapes: All services /metrics       │   │  ├─ Auto: CPU, Memory, Network           │
│  ├─ Stores: Time-series data             │   │  ├─ Custom: Application metrics          │
│  └─ Alerts: CPU > 80%, Errors > 5%       │   │  └─ Alarms: CPU > 80%, Errors > 5%       │
│                                          │   │                                          │
│  Loki (Logs)                             │   │  CloudWatch Logs                         │
│  ├─ Aggregates: Container logs           │   │  ├─ Streams: ECS task logs               │
│  ├─ Query: LogQL                         │   │  ├─ Query: CloudWatch Insights           │
│  └─ Retention: 30 days                   │   │  └─ Retention: 30 days                   │
│                                          │   │                                          │
│  Grafana (Dashboards)                    │   │  CloudWatch Dashboards                   │
│  ├─ Visualizes: Prometheus + Loki        │   │  ├─ Visualizes: CloudWatch Metrics/Logs  │
│  ├─ Dashboards: Per-service metrics      │   │  ├─ Dashboards: Per-service metrics      │
│  └─ Alerts: Slack/Email notifications    │   │  └─ Alerts: SNS/Email notifications      │
│                                          │   │                                          │
│  Implementation: Self-hosted in cluster  │   │  Implementation: AWS Managed Services    │
│                                          │   │                                          │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘

┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  AUTOMATION & JOBS                       │   │  AUTOMATION & JOBS                       │
├──────────────────────────────────────────┤   ├──────────────────────────────────────────┤
│                                          │   │                                          │
│  Database Migration (Job)                │   │  Database Migration (Lambda)             │
│  ├─ Runs: Once on deployment             │   │  ├─ Trigger: CodeDeploy pre-hook         │
│  ├─ Creates: Tables and indexes          │   │  ├─ Executes: SQL migrations             │
│  └─ Restart Policy: OnFailure            │   │  └─ Timeout: 5 minutes                   │
│                                          │   │                                          │
│  Transaction Timeout Handler (CronJob)   │   │  Transaction Timeout (EventBridge)       │
│  ├─ Schedule: Every minute               │   │  ├─ Schedule: Every minute (cron)        │
│  ├─ Reverses: Stuck transactions         │   │  ├─ Triggers: Lambda function            │
│  └─ History: Keep last 3 successful      │   │  └─ Execution: Lambda with RDS access    │
│                                          │   │                                          │
│  Implementation: Kubernetes Jobs/CronJobs│   │  Implementation: AWS Lambda + EventBridge│
│                                          │   │                                          │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    KEY TAKEAWAYS                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                           │
│  1. SAME SERVICES: Frontend, API Gateway, Auth, Wallet, Transaction, Notification        │
│                                                                                           │
│  2. SAME PATTERNS: Stateless services (scale horizontally), stateful infra (managed)     │
│                                                                                           │
│  3. SAME NETWORK DESIGN: Single ingress → API Gateway → Backends → Infrastructure        │
│                                                                                           │
│  4. SAME SECURITY: Zero-trust network, default deny, explicit allow                      │
│                                                                                           │
│  5. DIFFERENT BOXES: Kubernetes primitives ↔ AWS managed services                        │
│                                                                                           │
│  6. PHILOSOPHY: Architecture is platform-agnostic. Implementation is platform-specific.  │
│                                                                                           │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Workload Classification

### Stateless Workloads (Can Die and Restart Freely)

**Definition**: These services hold no state in memory or disk. If a container crashes and restarts, nothing is lost.

**Services**:
- **API Gateway** (2 replicas minimum)
- **Auth Service** (2 replicas minimum)
- **Wallet Service** (2 replicas minimum)
- **Transaction Service** (3 replicas minimum)
- **Notification Service** (2 replicas minimum)
- **Frontend** (2 replicas minimum)

**Why They're Stateless**:
1. **API Gateway**: Doesn't store requests. Routes traffic to backends. Uses Redis for idempotency keys (stored externally).
2. **Auth Service**: Doesn't store sessions in memory. Uses PostgreSQL for user data, Redis for token blacklist. JWT tokens are self-contained.
3. **Wallet Service**: Pure business logic. All wallet data in PostgreSQL. Queries database on every request.
4. **Transaction Service**: Business logic only. Transactions stored in PostgreSQL, queued to RabbitMQ. No in-memory state.
5. **Notification Service**: Consumes from RabbitMQ, sends notifications, acknowledges messages. No state between messages.
6. **Frontend**: Static React build served by Nginx. No server-side state.

**Consequences**:
- Can scale horizontally (add more replicas) without coordination
- Can be killed and restarted without data loss
- Load balancers can distribute traffic to any replica
- Updates can be done with rolling deployments (kill old, start new)
- Crash = inconvenience, not disaster

**Implementation Requirements** (Platform-Agnostic):
- Must run multiple replicas for high availability
- Must use external storage for all persistent data (database, cache, queue)
- Must be designed for load balancing (no sticky sessions)
- Must have health checks to detect when unhealthy
- Must handle graceful shutdown (finish processing current request before dying)

---

### Stateful Workloads (Must Maintain Identity and Data)

**Services**:
- **PostgreSQL** (1 replica - single source of truth)

**Why It's Stateful**:
1. **PostgreSQL**: Stores all critical data (users, wallets, transactions). Data persists across restarts.
2. **Stable Network Identity**: Always accessible at `postgres:5432`. Services expect this hostname.
3. **Persistent Volume**: Data written to `/var/lib/postgresql/data` must survive container restarts.
4. **Ordered Startup/Shutdown**: Database must initialize before applications connect. Shutdown must flush writes to disk.

**Consequences**:
- Cannot scale horizontally without replication/sharding (complex)
- Cannot be killed without risk of data corruption if not done gracefully
- Requires persistent storage (EBS volume, PersistentDisk, etc.)
- Requires stable DNS name (applications connect to fixed hostname)
- Requires careful backup strategy (not handled by restarting)

**Implementation Requirements** (Platform-Agnostic):
- Must have persistent volume attached (survives container death)
- Must have stable hostname/DNS name (other services depend on it)
- Must use ordered startup (database initializes before apps connect)
- Must have automated backups (separate from application lifecycle)
- Must handle graceful shutdown (flush writes, close connections)

---

### Semi-Stateful Workloads (State Can Be Lost, But Prefer Persistence)

**Services**:
- **Redis** (1 replica with persistent volume)
- **RabbitMQ** (1 replica - messages should persist)

**Why They're Semi-Stateful**:

**Redis**:
1. **Purpose**: Cache, session store, idempotency keys, rate limiting counters
2. **Data Nature**: Mostly ephemeral (cache can be rebuilt), but some data is critical (idempotency keys)
3. **Persistence Strategy**: Append-only file (AOF) for durability, but not as critical as PostgreSQL
4. **Failure Impact**: Cache miss = slower, not broken. Idempotency key loss = potential duplicate transactions (rare).

**RabbitMQ**:
1. **Purpose**: Message queue for asynchronous transaction processing and notifications
2. **Data Nature**: Messages in flight (transactions waiting to be processed)
3. **Persistence Strategy**: Messages should survive restarts (durable queues)
4. **Failure Impact**: Lost messages = lost transactions/notifications (bad, but not catastrophic - can replay)

**Consequences**:
- **Redis**: Can restart with empty cache (system slower, not broken). Persistent volume preferred to keep idempotency keys.
- **RabbitMQ**: Can restart with empty queue if messages aren't durable. Persistent volume required if messages must survive restarts.

**Implementation Requirements** (Platform-Agnostic):
- **Redis**: Persistent volume optional (depends on tolerance for cache loss). AOF enabled for durability.
- **RabbitMQ**: Persistent volume recommended. Queues should be marked durable.
- Both should have stable DNS names (services connect to fixed hostnames)
- Both should have health checks (detect when unavailable)

---

### Ephemeral Workloads (Designed to Be Temporary)

**Services**:
- **Database Migration Job** (runs once, completes, never runs again)
- **Transaction Timeout Handler CronJob** (runs every minute, completes, waits for next schedule)

**Why They're Ephemeral**:
1. **Migration Job**: Creates database schema. Runs once at deployment. Completion = success. Never needs to run again unless schema changes.
2. **Timeout Handler**: Reverses stuck transactions. Runs every minute. Each run is independent. No state between runs.

**Consequences**:
- Do not need high availability (if job fails, retry or run again)
- Do not need persistent storage (no data to save)
- Do not need load balancing (not serving traffic)
- Success = job completes with exit code 0

**Implementation Requirements** (Platform-Agnostic):
- **Jobs**: Run to completion. Retry on failure (up to backoff limit). Do not restart after success.
- **CronJobs**: Run on schedule. Each execution is independent. Failed runs do not block future runs.
- Both need access to database (connect to PostgreSQL)
- Both should have logging (track what they did)

---

## Network Architecture

### Traffic Flow Layers

**Layer 1: External → Ingress**
- **Who**: Internet users, external clients
- **To**: Load balancer or ingress controller
- **Protocol**: HTTPS (TLS termination at ingress)
- **Purpose**: Bring external traffic into the system

**Layer 2: Ingress → Frontend / API Gateway**
- **Who**: Ingress controller
- **To**: Frontend service (port 80) and API Gateway service (port 80)
- **Protocol**: HTTP (TLS terminated at ingress, internal traffic is plain HTTP)
- **Routing**:
  - `www.swiftpay.local/` → Frontend (React app)
  - `www.swiftpay.local/api/*` → API Gateway (backend API)
  - `api.swiftpay.local/` → API Gateway (alternative domain)

**Layer 3: API Gateway → Backend Services**
- **Who**: API Gateway
- **To**: Auth (3004), Wallet (3001), Transaction (3002), Notification (3003)
- **Protocol**: HTTP (internal service-to-service)
- **Purpose**: Route requests to correct backend based on URL path
- **Example**:
  - `/api/auth/login` → `auth-service:3004/auth/login`
  - `/api/wallet/balance` → `wallet-service:3001/wallet/balance`
  - `/api/transactions` → `transaction-service:3002/transactions`

**Layer 4: Backend Services → Infrastructure**
- **Who**: Auth, Wallet, Transaction, Notification services
- **To**: PostgreSQL (5432), Redis (6379), RabbitMQ (5672)
- **Protocol**: Native protocols (PostgreSQL wire protocol, Redis protocol, AMQP)
- **Purpose**: Data persistence, caching, message queueing

**Layer 5: Service-to-Service (Peer Communication)**
- **Who**: Transaction Service
- **To**: Wallet Service (3001)
- **Protocol**: HTTP
- **Purpose**: Transaction Service needs to update wallet balances
- **Example**: Transaction Service calls `wallet-service:3001/wallet/transfer` to move money

---

### Network Segmentation (Zero Trust)

**Principle**: By default, no pod can talk to any other pod. Communication must be explicitly allowed.

**Rules**:

1. **Frontend**:
   - **Ingress**: Allow from anywhere (internet users)
   - **Egress**: Not needed (serves static files)

2. **API Gateway**:
   - **Ingress**: Allow from anywhere (ingress controller, load balancer)
   - **Egress**: Allow to Auth, Wallet, Transaction, Notification services only
   - **Why**: API Gateway must route to backends, but shouldn't access databases directly

3. **Backend Services** (Auth, Wallet, Transaction, Notification):
   - **Ingress**: Allow from API Gateway only
   - **Egress**: Allow to PostgreSQL, Redis, RabbitMQ only
   - **Why**: Backends should only be called by API Gateway, not directly from internet

4. **Transaction Service** (Special Case):
   - **Ingress**: Allow from API Gateway only
   - **Egress**: Allow to PostgreSQL, Redis, RabbitMQ, **and Wallet Service**
   - **Why**: Transaction Service needs to update wallet balances (calls Wallet Service directly)

5. **Databases** (PostgreSQL, Redis, RabbitMQ):
   - **Ingress**: Allow from backend services only
   - **Egress**: Not needed (don't initiate connections)
   - **Why**: Databases should only be accessed by application services, not by API Gateway or frontend

6. **DNS** (Universal):
   - **Egress**: Allow all pods to access DNS (UDP port 53)
   - **Why**: Service discovery requires DNS lookups (e.g., `postgres` → `10.1.5.2`)

**Consequences**:
- If API Gateway is compromised, attacker cannot directly access databases
- If a backend service is compromised, attacker cannot access other backend services (except Transaction → Wallet)
- Network policies enforce defense in depth

**Implementation Requirements** (Platform-Agnostic):
- AWS: Use Security Groups (EC2), Network ACLs (VPC), or PrivateLink
- GCP: Use VPC Firewall Rules, Private Service Connect
- Azure: Use Network Security Groups (NSG), Application Security Groups (ASG)
- Kubernetes: Use NetworkPolicies
- Docker: Use custom bridge networks with isolated subnets

---

### Service Discovery

**Principle**: Services must be able to find each other using stable names, not IP addresses.

**Why**:
- IP addresses change when pods restart
- Load balancing requires distributing traffic across multiple replicas
- Configuration is easier with names (e.g., `postgres:5432`) than IPs

**Requirements** (Platform-Agnostic):
- **DNS-based discovery**: Services register with DNS (e.g., `auth-service`, `postgres`)
- **Internal DNS zone**: Services are not exposed to public DNS
- **Load balancing**: Service names resolve to multiple IPs if there are multiple replicas
- **Health checks**: Unhealthy replicas are removed from DNS/load balancer pool

**Examples**:
- `postgres` → Single IP (one database instance)
- `auth-service` → Multiple IPs (2+ replicas, load balanced)
- `redis` → Single IP (one cache instance)
- `rabbitmq` → Single IP (one queue instance)

---

## Ingress Strategy

### Single Entry Point

**Principle**: All external traffic enters through one ingress point (load balancer or ingress controller).

**Why**:
1. **Security**: Only one service is exposed to the internet. Reduces attack surface.
2. **TLS Termination**: Decrypt HTTPS once at the edge. Internal traffic is plain HTTP (faster).
3. **Rate Limiting**: Apply rate limits at ingress (100 requests/minute per IP).
4. **Monitoring**: Single point to monitor all incoming traffic.
5. **Routing**: Route based on hostname and path (domain-based or path-based routing).

**Routing Rules**:

1. **Frontend Routing** (`www.swiftpay.local`):
   - `/` → Frontend service (React app)
   - `/api/*` → API Gateway (backend API)
   - **Why**: Users visit `www.swiftpay.local`, frontend makes API calls to `/api/*`

2. **API Gateway Routing** (`api.swiftpay.local`):
   - `/` → API Gateway directly
   - **Why**: Alternative domain for API-only clients (mobile apps, third-party integrations)

**TLS Strategy**:
- **Local Development**: Self-signed certificate (browsers show warning)
- **Production**: Let's Encrypt certificate (automatic renewal)
- **Termination Point**: TLS is terminated at ingress. Backend traffic is HTTP.
- **Why**: Internal traffic doesn't need encryption (trusted network). Reduces CPU overhead.

**Consequences**:
- If ingress is down, entire system is unreachable (single point of failure)
- Ingress must be highly available (run multiple replicas)
- Ingress must have health checks (detect when unhealthy)

**Implementation Requirements** (Platform-Agnostic):
- AWS: Use Application Load Balancer (ALB) with target groups, Route53 for DNS
- GCP: Use Cloud Load Balancing with URL maps, Cloud DNS
- Azure: Use Application Gateway with backend pools, Azure DNS
- Kubernetes: Use Ingress Controller (Nginx, Traefik, Istio)
- Docker: Use Nginx or Traefik as reverse proxy

---

## Failure Expectations & Resilience

### What Can Crash and Recover

**Stateless Services** (API Gateway, Auth, Wallet, Transaction, Notification, Frontend):
- **Expected Failure Rate**: Rare, but possible (out of memory, bugs, infrastructure issues)
- **Impact**: Service is unavailable until another replica takes over
- **Recovery**: Automatic (orchestrator restarts crashed container)
- **Mitigation**:
  - Run multiple replicas (2-3 minimum)
  - Use health checks (liveness probe = restart if unhealthy, readiness probe = remove from load balancer)
  - Use Pod Disruption Budgets (ensure minimum replicas during updates)
- **Example Scenario**:
  - Auth Service replica 1 crashes (out of memory)
  - Load balancer detects failure (health check fails)
  - Load balancer routes traffic to replica 2
  - Orchestrator restarts replica 1
  - Replica 1 becomes healthy, load balancer adds it back

---

### What Cannot Crash Without Consequences

**PostgreSQL**:
- **Expected Failure Rate**: Should never crash (critical data)
- **Impact**: Entire system is down (all services depend on database)
- **Recovery**: Manual or orchestrator restart. Must validate data integrity.
- **Mitigation**:
  - Persistent volume (data survives crash)
  - Automated backups (restore if data is corrupted)
  - Health checks (detect crash early)
  - Graceful shutdown (flush writes before stopping)
- **Example Scenario**:
  - PostgreSQL crashes (kernel panic)
  - All backend services fail health checks (can't connect to database)
  - Orchestrator restarts PostgreSQL container
  - PostgreSQL recovers from persistent volume
  - Backend services reconnect and resume

**Consequences of Data Loss**:
- Lost users = can't log in (must re-register)
- Lost wallets = can't check balance (must recreate)
- Lost transactions = money disappears (catastrophic)
- **This is unacceptable**. PostgreSQL must never lose data.

---

### Dependency Chain and Startup Order

**Problem**: Services depend on each other. If PostgreSQL isn't ready, backend services crash.

**Real-World Example** (from our troubleshooting):
- Auth Service starts before PostgreSQL is ready
- Auth Service tries to connect: `Error: getaddrinfo ENOTFOUND postgres`
- Auth Service crashes (exits with error)
- Orchestrator restarts Auth Service (crash loop)
- Auth Service crashes again (PostgreSQL still not ready)
- **CrashLoopBackOff**: Auth Service keeps restarting, never becomes healthy

**Root Cause**: Startup order is not enforced. Auth Service assumes PostgreSQL is ready.

**Solution** (Platform-Agnostic):
1. **Wait-for-it Strategy**: Services should retry database connections (exponential backoff)
2. **Health Checks**: Services should report unhealthy if database is unreachable (don't crash, just wait)
3. **Init Containers**: Run a container before the main container to wait for dependencies
4. **Depends-on Ordering**: Orchestrator starts dependencies first (PostgreSQL before Auth Service)

**Example Implementation**:
```javascript
// Auth Service startup code
async function connectToDatabase() {
  let retries = 10;
  while (retries > 0) {
    try {
      await pool.connect();
      console.log("Connected to PostgreSQL");
      return;
    } catch (err) {
      console.error(`Database not ready, retrying... (${retries} retries left)`);
      retries--;
      await sleep(5000); // Wait 5 seconds before retry
    }
  }
  throw new Error("Could not connect to database after 10 retries");
}
```

**Consequences**:
- Services must be designed to tolerate dependency failures
- Health checks must accurately reflect readiness
- Resource quotas must allow for database resources (if quota is exceeded, database can't start)

---

### Circuit Breaking and Graceful Degradation

**Principle**: If a downstream service is failing, stop calling it (fail fast instead of cascading failure).

**Example**:
- Transaction Service calls Wallet Service to update balance
- Wallet Service is down (all replicas crashed)
- Without Circuit Breaker: Transaction Service keeps retrying, times out after 30 seconds, users wait forever
- With Circuit Breaker: After 5 failed requests, circuit opens. Future requests fail immediately with error "Wallet Service unavailable"

**Benefits**:
1. Faster failures (fail in 1ms instead of 30 seconds)
2. Reduced load on failing service (give it time to recover)
3. Better user experience (show error immediately instead of hanging)

**Implementation**: API Gateway uses circuit breaker pattern (Opossum library in Node.js).

---

## Data Persistence Strategy

### What Must NEVER Lose Data

**PostgreSQL** (Critical Business Data):
- **Users**: Email, password hash, name, role
- **Wallets**: User balances (money)
- **Transactions**: Money transfers (audit trail)

**Why It Can't Be Lost**:
- Users can't log in (must re-register)
- Wallet balances reset to zero (lose money)
- Transaction history is gone (compliance violation, legal issues)

**Persistence Requirements**:
1. **Persistent Volume**: Data stored on disk that survives container restarts (EBS, PersistentDisk, Azure Disk)
2. **Volume Size**: 10GB minimum (enough for millions of transactions)
3. **Backup Strategy**: Automated daily backups, stored separately from database
4. **Replication** (Optional): Master-replica setup for high availability (read replicas for scaling)

**Implementation** (Platform-Agnostic):
- AWS: RDS for PostgreSQL (managed), or EC2 with EBS volumes (self-managed)
- GCP: Cloud SQL (managed), or GCE with Persistent Disks (self-managed)
- Azure: Azure Database for PostgreSQL (managed), or VM with Managed Disks (self-managed)
- Kubernetes: StatefulSet with PersistentVolumeClaim (hostPath, EBS CSI driver, etc.)
- Docker: Volume mount to host filesystem (`-v /data/postgres:/var/lib/postgresql/data`)

---

### What SHOULD Persist (But Can Be Rebuilt)

**Redis** (Cache, Idempotency Keys, Rate Limiting):
- **What's Stored**:
  - Cache: User sessions, frequently accessed data (wallet balances)
  - Idempotency Keys: Prevent duplicate transactions (e.g., "transaction-123-abc" already processed)
  - Rate Limiting: Request counts per IP (e.g., "user-1.2.3.4: 95 requests this minute")

**Why Persistence is Preferred**:
- **Cache Loss**: Slower (cache miss = database query), but not broken
- **Idempotency Key Loss**: Potential duplicate transactions (user clicks "Send Money" twice, both transactions process)
- **Rate Limit Loss**: Rate limits reset (user can bypass limits for 1 minute until counters rebuild)

**Consequences of Data Loss**:
- System is slower (cache rebuilds from database)
- Potential duplicate transactions (rare, but possible)
- Rate limits are temporarily ineffective

**Persistence Strategy**:
1. **Persistent Volume**: 1GB minimum (Redis uses little disk space)
2. **Append-Only File (AOF)**: Redis writes every command to disk (durable, but slower)
3. **Backup**: Not critical (cache can be rebuilt)

**Implementation** (Platform-Agnostic):
- AWS: ElastiCache for Redis (managed), or EC2 with EBS volumes (self-managed)
- GCP: Cloud Memorystore (managed), or GCE with Persistent Disks (self-managed)
- Azure: Azure Cache for Redis (managed), or VM with Managed Disks (self-managed)
- Kubernetes: Deployment with PersistentVolumeClaim
- Docker: Volume mount to host filesystem (`-v /data/redis:/data`)

---

### What SHOULD Persist (Messages Must Survive Restarts)

**RabbitMQ** (Message Queue):
- **What's Stored**:
  - Transaction messages: "Process transaction 123: User 1 sends $50 to User 2"
  - Notification messages: "Send email to user@example.com: Transaction completed"

**Why Persistence is Required**:
- **Message Loss**: Lost transactions (money disappears), lost notifications (users don't know money was sent)
- **Consequences**: Silent failures (transaction appears successful, but never processes)

**Persistence Strategy**:
1. **Durable Queues**: RabbitMQ marks queues as durable (survive restarts)
2. **Persistent Messages**: Messages are written to disk before acknowledgment
3. **Persistent Volume**: Not strictly required if messages are durable, but preferred for cluster mode

**Implementation** (Platform-Agnostic):
- AWS: Amazon MQ (managed RabbitMQ), or EC2 with EBS volumes (self-managed)
- GCP: Cloud Pub/Sub (alternative to RabbitMQ), or GCE with Persistent Disks (self-managed)
- Azure: Azure Service Bus (alternative to RabbitMQ), or VM with Managed Disks (self-managed)
- Kubernetes: Deployment with PersistentVolumeClaim (optional, but recommended)
- Docker: Volume mount to host filesystem (`-v /data/rabbitmq:/var/lib/rabbitmq`)

---

### What CAN Lose Data (Ephemeral by Design)

**Logs** (emptyDir volumes):
- **What's Stored**: Application logs (request logs, error logs, debug logs)
- **Why Ephemeral**: Logs are shipped to central logging system (Loki, CloudWatch, Stackdriver). Local logs are temporary.
- **Consequences of Loss**: Old logs are gone (but already shipped to central system)

**Implementation**:
- Logs written to `/app/logs` (ephemeral volume)
- Log shipper (Promtail, Fluentd) reads logs and sends to central system
- When pod is deleted, logs are deleted (but already backed up)

---

## Resource Patterns

### Requests vs Limits (The Contract)

**Requests**: "I need at least this much" (guaranteed minimum)
**Limits**: "I will never use more than this" (hard cap)

**Why Both?**
- **Requests**: Scheduler uses this to decide where to place pods (find node with enough free resources)
- **Limits**: Prevents one pod from starving others (if pod exceeds limit, it's killed)

**Example**:
```
Auth Service:
  Requests: 250m CPU, 256Mi memory (guaranteed minimum)
  Limits: 500m CPU, 512Mi memory (hard maximum)
```

**Scenario 1: Normal Load**
- Auth Service uses 200m CPU, 200Mi memory (within requests)
- Scheduler guarantees 250m CPU, 256Mi memory are always available

**Scenario 2: High Load**
- Auth Service uses 400m CPU, 400Mi memory (above requests, below limits)
- Auth Service can burst up to 500m CPU, 512Mi memory if available
- Other pods are not affected (their requests are still guaranteed)

**Scenario 3: Overload**
- Auth Service tries to use 600m CPU, 600Mi memory (exceeds limits)
- Orchestrator kills pod with "OOMKilled" (Out of Memory) error
- Orchestrator restarts pod (crash loop if it keeps happening)

---

### Resource Quotas (Namespace-Level Limits)

**Principle**: Set hard limits on total resources consumed by all pods in a namespace.

**Why**:
1. Prevent resource exhaustion (one service consuming all cluster resources)
2. Enable multi-tenancy (multiple teams sharing same cluster)
3. Force proper resource planning (can't deploy if quota is exceeded)

**Example**:
```
Namespace Quota:
  Total CPU Requests: 4 cores (across all pods)
  Total Memory Requests: 8GB (across all pods)
  Maximum Pods: 20
```

**Scenario**:
- Auth Service: 2 replicas × 250m CPU = 500m CPU
- Wallet Service: 2 replicas × 250m CPU = 500m CPU
- Transaction Service: 3 replicas × 250m CPU = 750m CPU
- PostgreSQL: 1 replica × 100m CPU = 100m CPU (missing in original YAML - caused crash loop!)
- Total: 1.85 cores (fits within 4 core quota)

**Real-World Example** (from our troubleshooting):
- Resource Quota requires all pods to have CPU/memory requests
- PostgreSQL StatefulSet was missing `resources` section
- PostgreSQL pod couldn't be created (quota violation)
- Auth Service crashed (couldn't connect to PostgreSQL)
- **Fix**: Added CPU/memory requests to PostgreSQL (100m CPU, 256Mi memory)

---

### Sizing Services (Right-Sizing)

**Principles**:
1. **Start Small**: Begin with conservative requests (100m CPU, 256Mi memory)
2. **Monitor**: Track actual usage (Prometheus metrics)
3. **Adjust**: Increase requests if usage is consistently high
4. **Overprovisioning**: Set limits 2x higher than requests (allow bursting)

**Examples**:

**Small Services** (Frontend, Redis):
- Requests: 50m CPU, 64Mi memory
- Limits: 100m CPU, 128Mi memory
- Why: Serve static files or simple cache operations (low resource needs)

**Medium Services** (Auth, Wallet, Notification):
- Requests: 250m CPU, 256Mi memory
- Limits: 500m CPU, 512Mi memory
- Why: Handle user requests, database queries, business logic (moderate resource needs)

**Large Services** (Transaction Service):
- Requests: 250m CPU, 256Mi memory (same as medium)
- Limits: 500m CPU, 512Mi memory
- Why: Same resources, but more replicas (3 minimum) for higher throughput

**Database** (PostgreSQL):
- Requests: 100m CPU, 256Mi memory (constrained by quota)
- Limits: 100m CPU, 512Mi memory
- Why: Single instance, limited by quota. In production, would allocate 1-2 full cores.

---

## Security Boundaries

### Principle: Defense in Depth

**Multiple Layers of Security**:
1. **Network Layer**: Network policies (who can talk to who)
2. **Application Layer**: Authentication (JWT tokens), authorization (role-based access)
3. **Container Layer**: Security contexts (run as non-root, read-only filesystem)
4. **Resource Layer**: Resource quotas (prevent DoS via resource exhaustion)
5. **Rate Limiting**: Prevent abuse (100 requests/minute per IP)

---

### Security Contexts (Container Hardening)

**Principle**: Run containers with least privilege (minimize damage if compromised).

**Settings**:
1. **runAsUser: 1000**: Run as non-root user (UID 1000 = node user in Node.js images)
2. **allowPrivilegeEscalation: false**: Prevent process from gaining more privileges
3. **readOnlyRootFilesystem: false**: Allow writes (needed for logs, temp files)

**Why**:
- If attacker compromises container, they can't escalate to root
- If attacker compromises container, they can't modify system files (if read-only filesystem)
- Reduces attack surface

**Tradeoff**: Some applications need write access (logs, temp files). Balance security with functionality.

---

### Secrets Management

**Principle**: Never hardcode secrets in code or configuration files.

**What's a Secret**:
- Database passwords
- JWT secret keys
- API keys
- TLS certificates

**Storage**:
- Kubernetes: Secrets (base64 encoded, not encrypted by default)
- AWS: Secrets Manager or Parameter Store (encrypted)
- GCP: Secret Manager (encrypted)
- Azure: Key Vault (encrypted)

**Access Control**:
- Services should only access secrets they need (principle of least privilege)
- Use IAM roles (AWS), Service Accounts (Kubernetes), Managed Identities (Azure)

**Rotation**:
- Secrets should be rotated regularly (e.g., every 90 days)
- Applications should support hot-reloading secrets (no restart required)

---

## Scaling Philosophy

### Horizontal Scaling (Add More Replicas)

**Principle**: Scale by adding more copies of the same service, not by making one service bigger.

**When to Scale**:
1. **CPU Usage > 70%**: Service is CPU-bound (add more replicas)
2. **Memory Usage > 80%**: Service is memory-bound (add more replicas)
3. **Response Time > 1s**: Service is overloaded (add more replicas)

**Auto-Scaling Rules**:

**API Gateway**: 2-10 replicas
- **Why**: Handles ALL incoming traffic. Must scale aggressively.
- **Trigger**: CPU > 70% or Memory > 80%
- **Strategy**: Fast scale-up (double replicas every 60s), slow scale-down (50% every 5 min)

**Auth Service**: 2-8 replicas
- **Why**: Handles login/registration (CPU-intensive due to password hashing)
- **Trigger**: CPU > 70% or Memory > 80%

**Wallet Service**: 2-8 replicas
- **Why**: Handles balance checks (database queries)
- **Trigger**: CPU > 70% or Memory > 80%

**Transaction Service**: 3-10 replicas (highest minimum)
- **Why**: Handles money transfers (most critical, highest load)
- **Trigger**: CPU > 70% or Memory > 80%
- **Note**: Already has 3 replicas minimum (higher than others)

**Notification Service**: 2-6 replicas (lowest maximum)
- **Why**: Sends notifications (asynchronous, can queue)
- **Trigger**: CPU > 70% or Memory > 80%
- **Note**: Lower max than others (notifications can tolerate delays)

**Frontend**: 2-6 replicas
- **Why**: Serves static files (lightweight)
- **Trigger**: CPU > 70% or Memory > 80%

---

### Vertical Scaling (Make Services Bigger)

**Principle**: Increase CPU/memory limits for a single replica.

**When to Use**:
- Stateful services that can't scale horizontally (PostgreSQL, Redis, RabbitMQ)
- Services with high memory requirements (in-memory processing)

**Tradeoff**:
- More expensive (bigger machines)
- Single point of failure (if one big replica fails, impact is larger)
- Use horizontal scaling when possible

**Example**:
- PostgreSQL: 100m CPU → 1000m CPU (10x increase)
- Redis: 128Mi memory → 1024Mi memory (8x increase)

---

### Scaling Limits (Why Not Scale to 100 Replicas?)

**Constraints**:
1. **Resource Quota**: Namespace limits total resources (can't exceed quota)
2. **Database Connections**: PostgreSQL has max connections (default 100). 100 replicas × 20 connections each = 2000 connections (exceeds limit)
3. **Cost**: More replicas = more machines = higher cost
4. **Complexity**: 100 replicas = harder to debug, monitor, and troubleshoot

**Best Practice**: Scale to meet demand, but don't over-scale. Monitor actual usage.

---

## Operational Concerns

### High Availability (Survive Failures)

**Principle**: No single point of failure.

**Rules**:
1. **Minimum 2 Replicas**: All stateless services have 2+ replicas
2. **Pod Disruption Budgets**: Ensure at least 1 replica is always available during updates
3. **Health Checks**: Detect unhealthy replicas and restart them
4. **Load Balancing**: Distribute traffic across replicas (if one fails, traffic goes to others)

**Example**:
- Auth Service: 2 replicas minimum, Pod Disruption Budget = 1 (at least 1 must be available)
- During rolling update: Replica 1 is killed → Replica 2 handles all traffic → Replica 1 restarts → Replica 2 is killed → Replica 1 handles traffic

---

### Zero-Downtime Deployments

**Principle**: Update services without downtime (users don't notice).

**Strategy**:
1. **Rolling Update**: Kill old replicas one at a time, start new replicas
2. **Readiness Probe**: New replica doesn't receive traffic until healthy
3. **Liveness Probe**: Old replica is killed if unhealthy
4. **Pod Disruption Budget**: Ensure minimum replicas during update

**Example**:
- Transaction Service: 3 replicas (A, B, C)
- Update to new version:
  1. Start new replica D (version 2)
  2. Wait for D to become healthy (readiness probe)
  3. Kill old replica A
  4. Start new replica E (version 2)
  5. Wait for E to become healthy
  6. Kill old replica B
  7. Start new replica F (version 2)
  8. Wait for F to become healthy
  9. Kill old replica C
- At all times, at least 2 replicas are serving traffic (Pod Disruption Budget)

---

### Monitoring and Observability

**Principle**: You can't fix what you can't see.

**Metrics** (Prometheus):
- CPU/Memory usage per service
- Request rate (requests per second)
- Error rate (errors per second)
- Response time (latency)
- Database connection pool usage
- Redis cache hit rate
- RabbitMQ queue depth

**Logs** (Loki):
- Application logs (errors, warnings, info)
- Audit logs (who did what, when)
- Access logs (HTTP requests)

**Traces** (Optional, not implemented):
- Request tracing (follow request through all services)
- Example: Frontend → API Gateway → Auth Service → PostgreSQL

**Alerts** (Prometheus Alertmanager):
- CPU > 80% for 5 minutes → Alert
- Error rate > 5% for 1 minute → Alert
- Database connection pool > 90% full → Alert

---

### Backup and Recovery

**What to Backup**:
1. **PostgreSQL**: Daily full backups, hourly incremental backups
2. **Redis**: Optional (can rebuild cache)
3. **RabbitMQ**: Optional (messages should be durable)
4. **ConfigMaps/Secrets**: Stored in version control (infrastructure as code)

**Recovery Time Objective (RTO)**: How long can we be down?
- Target: 15 minutes (time to restore database from backup)

**Recovery Point Objective (RPO)**: How much data can we lose?
- Target: 1 hour (last hourly backup)

**Disaster Recovery**:
- Automated backups to separate region (survive data center failure)
- Ability to recreate entire system from scratch (infrastructure as code)

---

## Design Principles Summary

### 1. Stateless by Default
- Design services to be stateless (no in-memory state, no local disk state)
- Store all state externally (database, cache, queue)
- Scale horizontally by adding replicas

### 2. Single Entry Point
- All external traffic enters through one ingress point
- TLS terminates at ingress (internal traffic is plain HTTP)
- Ingress routes to frontend and API Gateway

### 3. API Gateway Pattern
- API Gateway is the only entry point to backend services
- API Gateway handles authentication, rate limiting, routing
- Backend services only accept traffic from API Gateway

### 4. Asynchronous Where Possible
- Use message queues for non-critical operations (notifications)
- Use synchronous HTTP for critical operations (wallet balance updates)
- Don't block user requests waiting for slow operations

### 5. Fail Fast and Gracefully
- Use circuit breakers to prevent cascading failures
- Return errors immediately (don't wait for timeouts)
- Design for partial failures (one service down ≠ entire system down)

### 6. Zero Trust Network
- By default, no service can talk to any other service
- Explicitly allow necessary communication (network policies)
- Apply principle of least privilege

### 7. Defense in Depth
- Multiple layers of security (network, application, container, resource)
- Never rely on one security control
- Assume each layer can be breached

### 8. Observable by Design
- Emit metrics for all operations (requests, errors, latency)
- Log all important events (errors, warnings, audit trails)
- Make debugging easier by providing context (correlation IDs)

### 9. Infrastructure as Code
- All configuration in version control (Git)
- Reproducible deployments (destroy and recreate entire system)
- No manual changes (automation prevents human error)

### 10. Design for Failure
- Assume everything will fail (disk, network, service, data center)
- Multiple replicas for high availability
- Automated backups for disaster recovery
- Health checks to detect failures early
- Graceful degradation when dependencies fail

---

## Applying This Design to Any Platform

### AWS Implementation

**Compute**:
- Stateless services: ECS Fargate or EKS (Kubernetes on AWS)
- Stateful services: RDS for PostgreSQL, ElastiCache for Redis, Amazon MQ for RabbitMQ

**Networking**:
- Ingress: Application Load Balancer (ALB)
- Service Discovery: AWS Cloud Map or ECS Service Discovery
- Network Segmentation: Security Groups, Network ACLs

**Storage**:
- Persistent volumes: EBS volumes (block storage)
- Backups: RDS automated backups, EBS snapshots

**Monitoring**:
- Metrics: CloudWatch Metrics
- Logs: CloudWatch Logs
- Alerts: CloudWatch Alarms

---

### GCP Implementation

**Compute**:
- Stateless services: Cloud Run or GKE (Kubernetes on GCP)
- Stateful services: Cloud SQL for PostgreSQL, Cloud Memorystore for Redis, Cloud Pub/Sub (alternative to RabbitMQ)

**Networking**:
- Ingress: Cloud Load Balancing
- Service Discovery: GKE Service Discovery or Cloud Service Directory
- Network Segmentation: VPC Firewall Rules

**Storage**:
- Persistent volumes: Persistent Disks
- Backups: Cloud SQL automated backups, Persistent Disk snapshots

**Monitoring**:
- Metrics: Cloud Monitoring (formerly Stackdriver)
- Logs: Cloud Logging
- Alerts: Cloud Monitoring Alerts

---

### Azure Implementation

**Compute**:
- Stateless services: Container Instances or AKS (Kubernetes on Azure)
- Stateful services: Azure Database for PostgreSQL, Azure Cache for Redis, Azure Service Bus (alternative to RabbitMQ)

**Networking**:
- Ingress: Application Gateway
- Service Discovery: AKS Service Discovery or Azure Service Fabric
- Network Segmentation: Network Security Groups (NSG)

**Storage**:
- Persistent volumes: Managed Disks
- Backups: Azure Database automated backups, Managed Disk snapshots

**Monitoring**:
- Metrics: Azure Monitor
- Logs: Azure Log Analytics
- Alerts: Azure Monitor Alerts

---

### On-Premise Implementation

**Compute**:
- Stateless services: Kubernetes (self-hosted), Docker Swarm, or Nomad
- Stateful services: Self-hosted PostgreSQL, Redis, RabbitMQ

**Networking**:
- Ingress: Nginx, Traefik, or HAProxy
- Service Discovery: Kubernetes DNS, Consul, or Zookeeper
- Network Segmentation: Firewall rules, VLANs

**Storage**:
- Persistent volumes: NFS, Ceph, or local disks
- Backups: pg_dump (PostgreSQL), rsync, or Bacula

**Monitoring**:
- Metrics: Prometheus + Grafana
- Logs: Loki + Grafana, or ELK Stack (Elasticsearch, Logstash, Kibana)
- Alerts: Prometheus Alertmanager

---

## Final Thoughts

This design is **platform-agnostic** because it focuses on **principles**, not **tools**.

- **Stateless services** work the same whether they run in ECS, GKE, or Docker Swarm.
- **Network segmentation** applies to Security Groups (AWS), Firewall Rules (GCP), NSGs (Azure), or NetworkPolicies (Kubernetes).
- **Persistent storage** can be EBS (AWS), Persistent Disks (GCP), Managed Disks (Azure), or PersistentVolumeClaims (Kubernetes).
- **High availability** requires 2+ replicas, whether managed by ECS, GKE, AKS, or Kubernetes.

**The architecture is the same. Only the implementation details change.**

When migrating to AWS, ask:
1. **What is this workload?** (Stateless, stateful, ephemeral)
2. **What are its dependencies?** (Database, cache, queue)
3. **What are its failure modes?** (Crash, data loss, network partition)
4. **How do I replicate this design in AWS?** (Use ECS, RDS, ALB, etc.)

**This document is your blueprint.** The tools change, but the principles remain the same.

