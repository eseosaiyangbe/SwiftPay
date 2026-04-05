# Auth Service

**Port:** 3004 | **File:** `server.js` (625 lines)

## What this service owns

- **`users` table** — email, hashed password, role, account lock state
- **`refresh_tokens` table** — long-lived tokens for re-issuing access tokens
- **`audit_log` table** — every login, logout, password change with IP + timestamp
- **Redis keys** — `blacklist:{token}` (logged-out tokens), `lockout:{email}` (brute-force protection)

## Why it exists separately

Authentication is the most sensitive part of the system. Keeping it isolated means:
1. A bug in wallet-service can't accidentally expose auth logic
2. You can harden or scale auth independently (auth tends to get hammered during attacks)
3. The JWT secret lives in exactly one service — auth-service signs tokens, every other service just verifies the signature via the API Gateway

## How JWT works in this system

```
Register/Login → auth-service signs JWT → returns to browser
Browser sends JWT in Authorization header on every request
API Gateway calls auth-service /auth/verify → gets { userId, role }
Gateway adds userId/role as headers → forwards request to backend service
Backend service trusts those headers (it doesn't call auth-service itself)
```

The key thing: only auth-service signs tokens and only auth-service verifies them. Wallet-service and transaction-service never call auth-service — they just receive the `userId` the gateway already verified and attached as a header.

Access tokens expire in 24h. Refresh tokens in 7 days. Logged-out tokens go into Redis blacklist so they can't be reused even if they're not yet expired.

## Most interesting code to read first

| Where | Line | What it teaches |
|-------|------|----------------|
| `initDB()` | ~64 | Schema creation on startup — users, refresh tokens, audit log, indexes |
| `auditLog()` | ~146 | How to record every sensitive action for compliance |
| `generateTokens()` | ~166 | JWT signing — access token vs refresh token structure |
| `/auth/register` handler | ~211 | Bcrypt hashing, wallet creation in same DB transaction, audit log |
| `/auth/login` handler | ~282 | Brute-force protection, account lockout, Redis blacklist check |
| `/auth/verify` handler | ~487 | How the gateway validates tokens (called on every protected route) |

## Run it locally

```bash
cd ../..
docker compose up -d postgres redis
cd services/auth-service
npm install
npm run dev   # starts on port 3004
```

Or use the VS Code **"Debug Auth Service"** launch config.

## Health check

```bash
curl http://localhost:3004/health
# {"status":"healthy","postgres":"connected","redis":"connected"}
```

## Security design decisions worth studying

- **bcrypt rounds = 12** — slow enough to make brute force infeasible, fast enough for normal use
- **Refresh tokens in DB** — lets you invalidate all sessions for a user (not possible with stateless JWTs alone)
- **Redis blacklist** — near-instant token revocation without waiting for expiry
- **Account lockout** — 5 failed attempts → 30 min lockout, stored in Redis so it survives restarts

---

**Read next:** [`services/wallet-service`](../wallet-service/README.md) — now that users exist, learn how their money is stored and moved atomically.
