# Security and Reliability Fixes (Audit Remediation)

This document summarizes fixes applied in response to the fintech security and quality audit.

## Critical Fixes

### 1. Password change invalidates all sessions
- **Auth service**: After a successful password change, the current access token is blacklisted in Redis (remaining TTL), all refresh tokens for the user are deleted, and session invalidation is audit-logged. An attacker with a stolen token can no longer use it after the victim changes their password.

### 2. User and transaction IDs use UUIDs
- **Auth service**: New users get a UUID v4 (`uuid` package) instead of `user-${Date.now()}-${Math.random()...}`. Reduces collision risk and prevents enumerable, guessable IDs.
- **Transaction service**: Transaction IDs are now UUID v4 instead of `TXN-${Date.now()}-...`. Same package `uuid` is used.

### 3. Demo code removed from transaction processing
- **Transaction service**: The 2–4 second artificial `setTimeout` in `processTransaction()` was removed. No random failure logic was present in the current codebase; if reintroduced elsewhere, it must not ship to production.

## High-Priority Fixes

### 4. API Gateway: local JWT verification
- **API Gateway**: The `authenticate` middleware no longer calls auth-service `/auth/verify` on every request. It now verifies the JWT locally with `JWT_SECRET` and checks the Redis blacklist. Requires `JWT_SECRET` and `REDIS_URL` on the gateway (e.g. in docker-compose and K8s).

### 5. Connection pool sizing and health-check leak
- **All services**: Default Postgres pool size reduced from 20 to 5 (configurable via `PG_POOL_MAX`). With four app services plus migration/cron, this keeps total connections within RDS limits (e.g. db.t3.small).
- **API Gateway**: Infrastructure health check uses a single persistent `healthCheckPool` instead of creating a new Pool every 30 seconds, eliminating the connection leak.

### 6. Frontend: registration user object and polling
- **Auth service**: Register response now includes `user: { id, email, name, role: 'user' }` so the frontend receives a full user object.
- **Frontend**: Registration flow uses `data.user` (with fallback for `role`). Polling: wallet/transactions/notifications every 30s, metrics every 60s. No longer polls all four every 3s.

### 7. /api/metrics: authentication and caching
- **API Gateway**: `GET /api/metrics` now uses `authenticate` middleware. Response is cached for 30 seconds to avoid fan-out to three services on every request.

### 8. Notification emails: recipient display name
- **Notification service**: When `otherParty` in the payload is a user ID (e.g. `user-*` or UUID), the service looks up the user’s name from the `users` table and uses it in the email body instead of the raw ID.

### 9. Dead Swagger dependencies
- **API Gateway**: `swagger-jsdoc` and `swagger-ui-express` were removed from `package.json` as they were never wired up. Re-add and implement if API docs are required.

## Medium-Priority Fixes

### 10. Docker Compose restart policies
- **docker-compose.yml**: `restart: always` for postgres, redis, rabbitmq; `restart: unless-stopped` for auth, wallet, transaction, notification, api-gateway, and frontend. Crashed containers are restarted automatically.

### 11. Terraform production override
- **terraform/aws/managed-services/terraform.tfvars.example**: Comment added recommending `db_instance_class = "db.t3.medium"` (or larger) for production to avoid accidental prod apply with small instance.

## Remaining Recommendations (not implemented in this pass)

- **Rate limiter**: Auth-service rate limiter is in use; ensure `NODE_ENV=production` in production so limits are strict.
- **Circuit breaker**: API Gateway still uses a custom in-process circuit breaker; consider replacing with `opossum` (as in transaction-service) for consistency and half-open behavior.
- **Tests**: Add unit/integration tests for auth, wallet, notification, api-gateway, and frontend; mock DB/Redis in CI.
- **package-lock.json**: Generate and commit lock files in each service and use `npm ci` in Docker for deterministic builds.
- **Schema isolation**: Long-term, use separate DB schemas or databases per service; short-term, ensure notification-service does not depend on auth’s schema for anything beyond the documented user-name lookup for emails. See **`docs/ARCHITECTURE-MICROSERVICES-VS-MONOLITH.md`** for the full tradeoff (modular monolith vs. true microservices) and a concrete roadmap if you choose microservices.

## Deployment: Ensuring JWT_SECRET and REDIS_URL (API Gateway)

**Scan summary (codebase checked):**

- **docker-compose.yml** – api-gateway service has `JWT_SECRET` and `REDIS_URL` in `environment`. ✓  
- **k8s/base/deployments/api-gateway.yaml** – reads `JWT_SECRET` and `REDIS_URL` from Secret `db-secrets`. ✓  
- **k8s/deployments/api-gateway.yaml** – legacy manifest (e.g. used by `monitoring/DEPLOYMENT-GUIDE.md`) was missing both; now includes `NODE_ENV`, `JWT_SECRET`, and `REDIS_URL` from `db-secrets` (optional). ✓  
- **k8s/overlays/local/secrets-db-secrets.yaml** – defines `JWT_SECRET` and `REDIS_URL` in `db-secrets`. ✓  
- **k8s/overlays/eks/eks-external-secrets.yaml** – syncs `JWT_SECRET` and `REDIS_URL` into `db-secrets`. ✓  
- **k8s/overlays/aks/aks-external-secrets.yaml** – syncs only `JWT_SECRET`; added a commented example for `REDIS_URL` (add when using Azure Cache for Redis). ✓  
- **.env.example** – documents `JWT_SECRET` and `REDIS_URL` for standalone or local runs. ✓  

---

Local JWT verification in the API Gateway **requires** `JWT_SECRET` and `REDIS_URL`. Use the following per environment:

| Environment | How to set JWT_SECRET and REDIS_URL |
|-------------|-------------------------------------|
| **Docker Compose** | Already set in `docker-compose.yml` for the `api-gateway` service (`JWT_SECRET` and `REDIS_URL`). Change values in the compose file or use env files for local overrides. |
| **Kubernetes (base / local)** | The API Gateway deployment reads both from the `db-secrets` Secret. For local/minikube, apply `k8s/overlays/local/secrets-db-secrets.yaml` (it includes `JWT_SECRET` and `REDIS_URL`). |
| **Kubernetes (EKS)** | External Secrets syncs `db-secrets` from AWS Secrets Manager. Ensure the secret in Secrets Manager has keys `jwt_secret` (under `swiftpay/ENV/app/secrets`) and that the Redis secret has `url` (under `swiftpay/ENV/redis`). The EKS overlay maps these into `db-secrets` as `JWT_SECRET` and `REDIS_URL`; the API Gateway deployment was updated to inject **REDIS_URL** from `db-secrets` as well as `JWT_SECRET`. |
| **Kubernetes (AKS)** | AKS External Secrets (`k8s/overlays/aks/aks-external-secrets.yaml`) currently syncs `JWT_SECRET` only. Add `REDIS_URL` from your Azure Cache for Redis (or Key Vault) so `db-secrets` contains both; the API Gateway deployment reads them. A commented example is in the AKS ExternalSecret. |
| **Bare metal / VM / other** | Set environment variables when starting the process, e.g. `JWT_SECRET=... REDIS_URL=redis://... node server.js`, or use a process manager (systemd, PM2) that injects them from a secure store. |

**Check:** If either variable is missing in production, the gateway returns 503 for `JWT_SECRET` not configured, or falls back to `redis://redis:6379` for `REDIS_URL` (which will fail if Redis is not at that host). Verify after deploy:

```bash
# Kubernetes: check env on a running api-gateway pod (values are redacted in describe)
kubectl exec -n swiftpay deploy/api-gateway -- env | grep -E 'JWT_SECRET|REDIS_URL'
```

---

## UUIDs: New vs existing data

- **New users** (after this deploy): get a UUID v4 in `users.id`.
- **New transactions**: get a UUID v4 in `transactions.id`.
- **Existing rows** are unchanged; they keep their current IDs (e.g. `user-1735123456-abc`, `TXN-1703123456789-A3F9K2M`). The app supports both formats (e.g. notification-service treats both `user-*` and UUID as user IDs for name lookup).

## Other deployment notes

- **Auth service** register response now includes `user`; ensure frontend and any clients use it for consistent role and profile data after registration.
