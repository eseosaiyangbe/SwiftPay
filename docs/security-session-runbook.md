# SwiftPay Security And Session Runbook

This runbook documents the first pass of Phase 4: Security And Session Hardening.

The goal is to make SwiftPay safer without changing the user-facing flow. The current focus is backend token safety, CORS behavior, and repeatable verification.

## What We Changed

### Production JWT Secret Guard

Files:

- `services/auth-service/server.js`
- `services/api-gateway/middleware/auth.js`

Both services now reject weak JWT secrets when `NODE_ENV=production`.

Rejected production values include:

- Missing `JWT_SECRET`.
- `dev-only-secret-change-in-production`.
- `your-super-secret-jwt-key-change-in-production-use-at-least-256-bits`.
- `your-secret-key`.
- `change-me`.
- Any secret shorter than 32 characters.

Why:

- Access tokens must be verifiable across replicas.
- A fintech-style service must not boot in production with tutorial/default secrets.
- The API Gateway and Auth Service must agree on the same strong signing secret.

Local development still has a safe fallback so Docker Compose remains easy to run.

### Refresh Token Rotation

File:

- `services/auth-service/server.js`

The refresh endpoint now rotates refresh tokens.

Flow:

```text
1. Client sends current refresh token.
2. Auth Service verifies the token signature.
3. Auth Service checks the token exists in the database and is not expired.
4. Auth Service deletes the used refresh token.
5. Auth Service inserts the new refresh token.
6. Client receives a new access token and new refresh token.
```

Why:

- A refresh token should be one-time use.
- If a used refresh token is stolen or replayed, the service rejects it.
- This reduces the blast radius of token leakage.

Important implementation detail:

Refresh tokens now include a unique `jti` claim. Without this, two refresh tokens issued in the same second with the same payload can be identical.

### CORS Hardening

Files:

- `services/api-gateway/server.js`
- `.env.example`
- `docker-compose.yml`

The API Gateway now parses `CORS_ORIGIN` as a comma-separated list of trusted browser origins.

Development behavior:

- Empty `CORS_ORIGIN` is allowed.
- Local browser origins are accepted for Docker Compose convenience.

Production behavior:

- `CORS_ORIGIN` must be set.
- `CORS_ORIGIN=*` is rejected.
- Only explicit trusted origins are accepted.

Example:

```bash
CORS_ORIGIN=https://swiftpay.example.com,https://admin.swiftpay.example.com
```

Why:

- Credentialed browser requests should not use wildcard origins.
- Cloudflared, ingress, and Kubernetes deployments need explicit hostnames.
- This prepares us for the later Kubernetes and Cloudflared phases.

### Frontend Session Storage

Files:

- `services/frontend/src/lib/api-client.js`
- `services/frontend/src/App.js`

The frontend no longer stores tokens in `localStorage`.

Current behavior:

```text
1. Login/register stores access token, refresh token, and user profile in sessionStorage.
2. Browser tab refresh keeps the session.
3. Closing the browser tab/window clears the session.
4. App startup deletes older SwiftPay token values from localStorage.
5. Logout clears both sessionStorage and any legacy localStorage values.
```

Why:

- `localStorage` survives browser restarts, which increases token exposure time.
- `sessionStorage` is still browser-accessible JavaScript storage, but it is shorter-lived.
- This is a useful local hardening step before a larger HTTP-only cookie or backend-for-frontend design.

## Smoke Tests

### Refresh And Logout Security

Command:

```bash
npm run smoke:auth-security
```

Under the hood this runs:

```bash
bash scripts/smoke-auth-security.sh
```

The test verifies:

- A new user can register.
- A refresh token can be used once.
- The old refresh token is rejected after rotation.
- Logout succeeds with the current access token and refresh token.
- The logged-out access token is rejected by the API Gateway.

Run it from the SwiftPay repo root:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
source ~/.nvm/nvm.sh
npm run smoke:auth-security
```

Expected result:

```text
Auth security smoke test passed.
```

### Account Lockout And Password Change

Command:

```bash
npm run smoke:auth-deep
```

Under the hood this runs:

```bash
bash scripts/smoke-auth-deep.sh
```

The test verifies:

- A new user locks after repeated bad login attempts.
- The correct password is rejected while the account is locked.
- A separate user can change password through the API Gateway.
- The old access token is revoked after password change.
- The old refresh token is revoked after password change.
- The old password no longer works.
- The new password works.

Expected result:

```text
Deep auth security smoke test passed.
```

### Production Config Guards

Command:

```bash
npm run smoke:production-guards
```

Under the hood this runs:

```bash
bash scripts/smoke-production-config-guards.sh
```

The test verifies:

- Auth Service refuses weak `JWT_SECRET` in production mode.
- API Gateway refuses wildcard `CORS_ORIGIN=*` in production mode.
- API Gateway refuses weak `JWT_SECRET` in production mode.

Expected result:

```text
Production config guard smoke test passed.
```

## Useful Verification Commands

Check JavaScript syntax:

```bash
node --check services/auth-service/server.js
node --check services/api-gateway/server.js
node --check services/api-gateway/middleware/auth.js
```

Rebuild changed services:

```bash
docker compose up -d --build auth-service api-gateway
```

Run the Phase 4 smoke test:

```bash
npm run smoke:auth-security
npm run smoke:auth-deep
npm run smoke:production-guards
```

Run existing money-flow checks:

```bash
npm run smoke:send-money
npm run smoke:failed-transaction
npm run smoke:notifications
```

## Current Limitations

The frontend still stores tokens in browser-accessible JavaScript storage.

This is better than `localStorage` because the data is no longer durable across browser restarts, but it is not the final fintech-grade pattern.

The next frontend security step is to move toward HTTP-only cookies or a backend-for-frontend pattern.

## Production Notes

Before running SwiftPay in production or through a public Cloudflared tunnel:

```bash
export NODE_ENV=production
export JWT_SECRET='replace-with-a-long-random-secret'
export CORS_ORIGIN='https://your-real-swiftpay-hostname'
```

Do not use:

```bash
CORS_ORIGIN=*
JWT_SECRET=dev-only-secret-change-in-production
```
