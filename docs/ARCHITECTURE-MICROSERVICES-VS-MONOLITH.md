# Microservices vs. Modular Monolith: PayFlow Architecture Choice

The codebase today is a **distributed monolith**: multiple Node.js services, but one shared database, shared secrets, synchronous cross-service calls, and deployment as a unit. This doc lays out the tradeoff and two paths.

---

## If this repo is a demo for real-world fintech infra & DevOps

**Goal:** Show what production-style fintech looks like (K8s, Terraform, EKS, secrets, observability, multiple services) without the full complexity of “true” microservices.

**Recommendation: keep the multi-service layout and make it “demo-realistic”.**

- **Keep:** Separate services (api-gateway, auth, wallet, transaction, notification), separate K8s deployments, Terraform/EKS, External Secrets, RabbitMQ, Redis. That’s what you want to demo — real infra and DevOps patterns.
- **Tighten boundaries so it doesn’t look like a monolith:**
  - **No cross-service DB access:** e.g. notification-service gets recipient name from the **message payload** (transaction-service or gateway adds it), not by querying auth’s `users` table. That’s one code change and reads as “proper” service boundary.
  - **Gateway does auth** (JWT + Redis blacklist); backend services don’t need to share `JWT_SECRET` for request auth (they trust gateway or a token in the request).
- **Document the gap:** In the README or this doc, one short “Demo vs. production” section: “This demo uses one DB for simplicity. Production would add: database per service, event bus for async flows, etc.” So the audience sees the same patterns as real fintech, with a clear note on what’s simplified.

You don’t need full “database per service” or event-driven everything for the demo to look and feel like real stuff. You need **clear service boundaries** (no service reading another’s DB) and **realistic infra** (which you already have). That’s enough to show “this is how fintech infra and DevOps are done.”

---

## Why the audit called it a distributed monolith

| Microservices goal | PayFlow today |
|--------------------|----------------|
| **Independent deployability** | All services deploy together; DB migrations and shared schema tie releases. |
| **Fault isolation** | One DB and shared Redis; a DB outage takes down every service. |
| **Technology diversity** | All Node.js, one stack. |
| **Team autonomy** | One codebase, one DB; no team “owns” a bounded database. |
| **Scale independently** | Services share state (same DB); scaling one service doesn’t isolate load. |

Concrete issues:

- **One shared database** – auth, wallet, transaction, notification all use the same `payflow` DB and tables (e.g. `users`).
- **Shared secret** – `JWT_SECRET` is the same everywhere; no per-service identity boundary.
- **Sync coupling** – API Gateway used to call auth-service on every request (now fixed with local JWT verify); notification-service still reads auth’s `users` table for email/name.
- **Deploy as a unit** – K8s/docker-compose treat the app as one system; no “deploy only wallet-service” story.

So you get the operational cost of many services (networking, discovery, config, secrets, K8s) without the benefits (independent deploy, fault isolation, team/scaling boundaries).

---

## Two paths

### Path A: Embrace a modular monolith (recommended for MVP / small team)

**Idea:** One deployable app, one database, but clear internal modules (auth, wallet, transactions, notifications) with strict boundaries in code. Later you can extract modules into services when a real need appears.

**Pros:**

- Single deploy, one DB, one place for migrations and secrets.
- Easier to reason about, test, and run locally.
- Fits a small team and fintech MVP; you can ship and iterate fast.
- You can still keep the current “multi-process” layout (e.g. API gateway + workers) if you want, but all share one DB and one deployment story.

**Concrete steps:**

1. Merge the six Node services into one repo/app (e.g. one Express app with `/auth`, `/wallets`, `/transactions`, `/notifications` and internal modules).
2. Keep one Postgres DB and one Redis; run migrations and secrets once.
3. Enforce module boundaries in code (e.g. auth module never imports wallet repository; use clear interfaces).
4. Optionally keep RabbitMQ for async jobs (e.g. notifications, transaction processing) inside the same app.
5. Deploy one container (or gateway + worker if you split by process type, still one deploy unit).

**When to revisit:** When you have multiple teams, need to scale one domain much more than others, or need different tech (e.g. Python for ML). Then extract one module at a time into a real service with its own DB.

---

### Path B: Move toward true microservices

**Idea:** Keep multiple services but introduce real boundaries: database per service, no direct DB access across domains, async APIs where appropriate, and independent deployability.

**What “true” microservices imply:**

| Change | Today | Target |
|--------|--------|--------|
| **Data** | One DB; notification-service reads `users`. | Each service has its own DB or schema; no service touches another’s tables. |
| **Identity / secrets** | One `JWT_SECRET` for all. | Per-service or per-domain secrets; tokens validated at gateway or by auth only; other services trust gateway or auth’s signed context. |
| **Communication** | Sync HTTP + some RabbitMQ. | Prefer async (events/messages) for cross-domain work; sync only at API boundary (gateway → service). |
| **Deploy** | All-or-nothing. | Each service versioned and deployed independently; DB migrations belong to the service that owns the schema. |
| **Discovery / config** | Hardcoded or env URLs. | Service discovery + config (e.g. K8s DNS + ConfigMaps/Secrets or a mesh). |

---

## If you choose Path B: roadmap toward microservices

Use this as a checklist; order is intentional.

### Phase 1: Database and data ownership

1. **Database per service (or schema per service with strict ownership)**  
   - **Option A:** Separate Postgres DBs (e.g. `payflow_auth`, `payflow_wallet`, `payflow_transactions`, `payflow_notifications`). Each service connects only to its own DB.  
   - **Option B:** One Postgres instance, separate schemas (`auth`, `wallet`, `transactions`, `notifications`) and DB users so each service has access only to its schema.  
   - Migrate data and point each service at its own DB/schema. No service may `SELECT`/`INSERT` into another service’s tables.

2. **Remove cross-service DB access**  
   - **notification-service:** Must not query `users`. It should get “recipient name” and “recipient email” from the **payload** of the message it receives (published by transaction-service or auth after a lookup). Transaction-service (or a dedicated “user-info” client) gets user data from auth via a small API (e.g. “resolve user ids to names”) or from an event, and passes it in the notification payload.

3. **Auth as the only owner of `users`**  
   - Auth exposes a small internal API or events (e.g. “user created”, “user profile updated”). Other services never read auth’s DB; they get user data via API or events.

### Phase 2: API and communication boundaries

4. **API Gateway as single entrypoint**  
   - All client traffic goes through the gateway. Gateway does JWT verification (already in place), then calls backend services with a request context (user id, role). Backend services do not need to share `JWT_SECRET`; they trust the gateway or a short-lived internal token.

5. **Prefer async for cross-domain actions**  
   - Example: “Send money” → gateway calls transaction-service → transaction-service emits “TransactionCompleted” (or similar) with all data needed for notifications (amount, recipient name/email, etc.). Notification-service consumes the event and sends email; it does not look up users in a DB.

6. **Service discovery and config**  
   - In K8s, use DNS (e.g. `http://wallet-service.payflow.svc:3001`). Store URLs and feature flags in ConfigMaps/Secrets or a config service, not hardcoded in code.

### Phase 3: Independent deployability

7. **Version and deploy each service separately**  
   - CI/CD builds and deploys per service (e.g. only wallet-service when `services/wallet-service` changes). Migration jobs run as part of that service’s deployment (e.g. init container or Job in the same namespace).

8. **Backward-compatible contracts**  
   - Events and APIs must be versioned or backward-compatible so that when notification-service is updated, it still understands messages produced by the current transaction-service (and vice versa).

9. **Secrets per service**  
   - Each service has its own DB credentials and any service-specific secrets. Gateway (or auth) has `JWT_SECRET`; other services get only what they need (e.g. Redis URL for cache, no JWT_SECRET).

---

## Recommendation

- **For a fintech MVP and a small team:** Prefer **Path A (modular monolith)**. You get clarity, one deploy, one DB, and you can still keep the current process layout (gateway + workers) if useful. Revisit microservices when you have multiple teams or clear scaling/tech boundaries.
- **If you explicitly want microservices (Path B):** Start with **Phase 1** (database/schema per service, remove notification-service’s direct read of `users`, pass user data in payloads). Then Phase 2 (async events, gateway as single entrypoint), then Phase 3 (independent deploy and per-service secrets). Doing Phase 1 alone already moves you from “monolith with one DB” to “services with owned data.”

---

## References

- Audit: “This is not a microservices architecture. It’s a monolith with networking overhead.”
- Existing doc: `docs/SECURITY-AND-RELIABILITY-FIXES.md` (schema isolation, notification-service not querying auth’s tables).
- Code: notification-service today resolves `otherParty` by querying `users`; that’s the first cross-boundary dependency to replace with “data in payload” or a small auth API.
