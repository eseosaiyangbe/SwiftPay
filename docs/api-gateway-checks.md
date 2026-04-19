# What the API Gateway Actually Checks

> **Simple Explanation**: Every request that comes through the API Gateway goes through these checks in order.

---

## The Checks (In Order)

### 1. Security Headers (Helmet)
**What it checks:** Adds security headers to prevent common attacks
- X-Frame-Options (prevents clickjacking)
- X-XSS-Protection (prevents XSS attacks)
- Content-Security-Policy (prevents code injection)

**When:** Every request, automatically

**What happens if it fails:** Headers are added (no failure, just protection)

---

### 2. CORS (Cross-Origin Resource Sharing)
**What it checks:** Is the request coming from an allowed origin?

**Configuration:**
- Development: Allows all origins (`*`)
- Production: Should be specific domain

**When:** Every request

**What happens if it fails:** Request is blocked, browser shows CORS error

---

### 3. Rate Limiting
**What it checks:** How many requests has this IP made recently?

**Three Types of Rate Limiters:**

**General Rate Limiter** (all API routes):
- Development: 1000 requests per 15 minutes
- Production: 100 requests per 15 minutes

**Auth Rate Limiter** (login/register):
- Development: 50 attempts per 15 minutes
- Production: 5 attempts per 15 minutes
- **Why stricter?** Prevents brute force attacks

**Transaction Rate Limiter** (send money):
- Development: 100 requests per minute
- Production: 10 requests per minute
- **Why stricter?** Prevents spam transactions

**What happens if it fails:** Returns `429 Too Many Requests` with message "Too many requests from this IP"

---

### 4. Request Validation
**What it checks:** Is the request data in the correct format?

**Examples:**
- `userId` must be a non-empty string
- `amount` must be a number between 0.01 and 1,000,000
- `page` (for pagination) must be a positive integer

**When:** Before forwarding to backend service

**What happens if it fails:** Returns `400 Bad Request` with validation error details

**Example Error:**
```json
{
  "error": "Validation failed",
  "details": [
    {
      "field": "amount",
      "message": "Amount must be a number between 0.01 and 1000000"
    }
  ]
}
```

---

### 5. Authentication (JWT Token)
**What it checks:** Is the user logged in? Is the token valid?

**How it works:**
1. Extracts token from `Authorization: Bearer <token>` header
2. If no token → Returns `401 Authentication required`
3. Sends token to Auth Service: `POST /auth/verify`
4. Auth Service validates token and returns user info
5. If valid → Adds `req.user` with `userId`, `email`, `role`
6. If invalid → Returns `401 Invalid token`

**When:** Only for protected routes (marked with `authenticate` middleware)

**Protected Routes:**
- `/api/wallets/*` - Need to be logged in
- `/api/transactions/*` - Need to be logged in
- `/api/auth/logout` - Need to be logged in
- `/api/auth/me` - Need to be logged in

**Public Routes (no authentication):**
- `/api/auth/register` - Anyone can register
- `/api/auth/login` - Anyone can login
- `/health` - Health check (no auth needed)

**What happens if it fails:** Returns `401 Authentication required` or `401 Invalid token`

---

### 6. Authorization (Resource Ownership)
**What it checks:** Can this user access this resource?

**Two Types:**

**Owner Check** (`authorizeOwner`):
- Checks if `req.user.userId` matches the resource owner
- Example: User can only see their own wallet
- Admin users can access any resource

**Role Check** (`authorizeRole`):
- Checks if user has required role (e.g., `admin`)
- Example: Only admins can delete users

**When:** Only for routes that access user-specific resources

**Example:**
```javascript
// User tries to access: GET /api/wallets/user-123
// API Gateway checks:
// - Is user logged in? (authentication)
// - Is req.user.userId === "user-123" OR is user admin? (authorization)
// - If no → Returns 403 Access denied
```

**What happens if it fails:** Returns `403 Access denied - you can only access your own resources`

---

### 7. Circuit Breaker (Service Health)
**What it checks:** Is the backend service healthy? Should we even try calling it?

**How it works:**
- Tracks failures for each service
- If service fails 5 times in a row → Circuit opens
- When circuit is open → API Gateway rejects immediately (doesn't call service)
- After 1 minute → Circuit goes to "half-open" (test if service is back)
- If test succeeds → Circuit closes (service is healthy again)

**States:**
- **Closed (0)**: Service is working, call it normally
- **Open (1)**: Service is broken, reject requests immediately
- **Half-Open (2)**: Testing if service is back

**What happens if it fails:** Returns error immediately without calling the broken service (prevents cascading failures)

---

### 8. Request Size Limit
**What it checks:** Is the request body too large?

**Limit:** 10KB maximum

**When:** Before parsing JSON body

**What happens if it fails:** Request is rejected before processing

---

## Complete Flow Example: Sending Money

```
User clicks "Send $100"
    ↓
1. ✅ Security Headers - Added automatically
    ↓
2. ✅ CORS - Check origin (allowed)
    ↓
3. ✅ Rate Limiting - Check IP (under limit)
    ↓
4. ✅ Request Validation - Check amount (0.01-1000000), userIds (non-empty strings)
    ↓
5. ✅ Authentication - Check JWT token (valid, user logged in)
    ↓
6. ✅ Authorization - Check if req.user.userId === fromUserId (user owns the wallet)
    ↓
7. ✅ Circuit Breaker - Check if Transaction Service is healthy (circuit closed)
    ↓
8. ✅ Request Size - Check body size (< 10KB)
    ↓
9. ✅ Forward to Transaction Service
```

**If any check fails:** Request is rejected, user gets error message

---

## What the API Gateway Does NOT Check

**Idempotency (Duplicate Prevention):**
- ❌ API Gateway does NOT check for duplicate requests
- ✅ Transaction Service checks for duplicates (using Redis)

**Why?** Idempotency is handled at the service level, not the gateway level.

**Balance Validation:**
- ❌ API Gateway does NOT check if user has enough money
- ✅ Wallet Service checks this when processing the transfer

**Why?** Business logic belongs in services, not the gateway.

---

## Summary Table

| Check | What It Does | When | Failure Response |
|-------|-------------|------|------------------|
| **Security Headers** | Adds protection headers | Every request | N/A (always passes) |
| **CORS** | Checks request origin | Every request | CORS error (browser) |
| **Rate Limiting** | Counts requests per IP | Every request | 429 Too Many Requests |
| **Validation** | Checks data format | Before service call | 400 Bad Request |
| **Authentication** | Validates JWT token | Protected routes | 401 Authentication required |
| **Authorization** | Checks resource ownership | Protected routes | 403 Access denied |
| **Circuit Breaker** | Checks service health | Before service call | Error (service unavailable) |
| **Request Size** | Checks body size | Before parsing | Request rejected |

---

## Key Takeaways

1. **API Gateway is a security layer** - It protects your services from bad requests
2. **Checks happen in order** - If one fails, request stops there
3. **Different routes have different checks** - Public routes skip authentication
4. **Rate limiting prevents abuse** - Stops attackers from overwhelming your system
5. **Circuit breaker prevents cascading failures** - If one service breaks, it doesn't break everything

---

*Understanding what the API Gateway checks helps you debug issues and understand why requests are accepted or rejected.*

