# API Gateway

**Port:** 3000 | **File:** `server.js` (665 lines)

## What this service owns

The API Gateway is the single entry point for every request from the browser. It does three things and nothing else: verify identity (by calling auth-service), enforce rate limits, and route requests to the right backend service.

It owns **no database tables**. It stores nothing. It's a smart traffic cop.

## Why it exists separately

The browser only needs to know one address — the gateway. Without it, the frontend would need to know the address of auth-service, wallet-service, transaction-service, and notification-service separately, and each of those would need to re-implement auth checks. By centralising routing here, backend services can be moved, scaled, or replaced without changing the frontend at all.

## What flows through it

```
Browser → API Gateway :3000
  → /api/auth/*       → auth-service:3004
  → /api/wallets/*    → wallet-service:3001
  → /api/transactions/* → transaction-service:3002
  → /api/notifications/* → notification-service:3003
```

## Most interesting code to read first

| Where | What it teaches |
|-------|----------------|
| `server.js` lines 1–60 | Express setup, helmet, morgan, correlation ID middleware |
| Auth verify middleware | How the gateway delegates auth to auth-service on every protected route |
| Rate limiting setup | How to prevent abuse without a database (express-rate-limit + Redis) |
| Proxy route handlers | How axios forwards requests to downstream services with correlation ID headers |

## Run it locally (for debugging)

Infrastructure must be up: on the **MicroK8s** learning path, deploy the stack first ([`LEARNING-PATH.md`](../../LEARNING-PATH.md), [`docs/microk8s-deployment.md`](../../docs/microk8s-deployment.md)) and use **Run Task** / launch configs that point at cluster URLs—or for a **Compose-only** dev loop:

```bash
cd ../..
docker compose up -d postgres redis rabbitmq
cd services/api-gateway
npm install
npm run dev   # starts on port 3000
```

Or use the VS Code **"Debug API Gateway"** launch config — it starts with the debugger attached and all env vars pre-set.

## Environment variables

| Variable | Local default | Purpose |
|----------|--------------|---------|
| `PORT` | `3000` | Port to listen on |
| `AUTH_SERVICE_URL` | `http://localhost:3004` | Where to verify JWTs |
| `WALLET_SERVICE_URL` | `http://localhost:3001` | Wallet routing |
| `TRANSACTION_SERVICE_URL` | `http://localhost:3002` | Transaction routing |
| `NOTIFICATION_SERVICE_URL` | `http://localhost:3003` | Notification routing |
| `JWT_SECRET` | `dev-secret` | Must match auth-service |

## Health check

```bash
curl http://localhost:3000/health
# {"status":"healthy","services":{"auth":"up","wallet":"up","transaction":"up","notification":"up"}}
```

## Things to try

- Register a user: `POST /api/auth/register`
- Send a request without a JWT — watch it get rejected at the gateway, never reaching the backend
- Watch the correlation ID (`txn-...`) flow through logs across services — a **correlation ID** is a unique string attached to every request so you can trace one user action across multiple services' logs

---

**Read next:** [`services/frontend`](../frontend/README.md) — the final piece: how the browser talks to this gateway through nginx, and why a proxy is needed.
