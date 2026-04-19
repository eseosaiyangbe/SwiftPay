# Debugging "Send Money" Not Working - Docker Compose

> **Quick 5-Step Guide** for when the Send Money button is static/unresponsive in Docker Compose

---

## The 5 Checks (In Order)

### ✅ Check 1: Are All Services Running?

```bash
docker-compose ps
```

**What to look for:**
- All services should show `Up` status
- No services showing `Exit` or `Restarting`

**If something is down:**
```bash
# Check logs for the down service
docker-compose logs <service-name>

# Restart the service
docker-compose restart <service-name>
```

**Common issue:** Transaction service or RabbitMQ might be down.

---

### ✅ Check 2: Is RabbitMQ Running and Accessible?

```bash
# Check RabbitMQ is running
docker-compose ps rabbitmq

# Check RabbitMQ logs
docker-compose logs rabbitmq | tail -20
```

**What to look for:**
- RabbitMQ should show `Up` status
- Logs should show "Server startup complete" (no errors)

**If RabbitMQ is down:**
```bash
docker-compose restart rabbitmq
# Wait 10 seconds, then check again
docker-compose ps rabbitmq
```

**Why this matters:** Send Money uses RabbitMQ to queue transactions. If RabbitMQ is down, transactions can't be processed.

---

### ✅ Check 3: Can Transaction Service Connect to RabbitMQ?

```bash
# Check transaction service logs
docker-compose logs transaction-service | tail -30
```

**What to look for:**
- ✅ Good: "Connected to RabbitMQ" or "Channel created"
- ❌ Bad: "ECONNREFUSED", "Connection failed", or "Error connecting to RabbitMQ"

**If connection fails:**
```bash
# Restart transaction service (it will retry connection)
docker-compose restart transaction-service

# Wait 5 seconds, check logs again
docker-compose logs transaction-service | tail -10
```

**Why this matters:** Transaction service needs RabbitMQ to queue money transfers.

---

### ✅ Check 4: Is the Database Connected?

```bash
# Check if PostgreSQL is running
docker-compose ps postgres

# Check transaction service can reach database
docker-compose logs transaction-service | grep -i "database\|postgres\|connected"
```

**What to look for:**
- ✅ Good: "Database connected" or "PostgreSQL connection established"
- ❌ Bad: "ECONNREFUSED", "Connection refused", or "Database connection failed"

**If database connection fails:**
```bash
# Restart postgres
docker-compose restart postgres

# Wait 5 seconds, restart transaction service
docker-compose restart transaction-service
```

**Why this matters:** Transactions are stored in the database. If the database is unreachable, transactions can't be saved.

---

### ✅ Check 5: Check Browser Console for Errors

**In the browser:**
1. Open Developer Tools: `F12` or `Cmd+Option+I` (Mac) / `Ctrl+Shift+I` (Windows)
2. Go to **Console** tab
3. Click "Send Money" button
4. Look for red error messages

**Common errors to look for:**
- `Failed to fetch` → API Gateway might be down
- `401 Unauthorized` → Not logged in or token expired
- `Network error` → Frontend can't reach API Gateway
- `ECONNREFUSED` → Service connection issue

**If you see errors:**
```bash
# Check API Gateway logs
docker-compose logs api-gateway | tail -20

# Check if API Gateway is running
docker-compose ps api-gateway
```

---

## Quick Fix Commands

**If Send Money still doesn't work after all checks:**

```bash
# Restart all services (nuclear option)
docker-compose restart

# Or restart just the critical services
docker-compose restart transaction-service rabbitmq postgres api-gateway

# Check everything is up
docker-compose ps
```

---

## Most Common Issues (Quick Reference)

| Issue | Symptom | Fix |
|-------|---------|-----|
| RabbitMQ down | Button clicks but nothing happens | `docker-compose restart rabbitmq` |
| Transaction service can't connect | Logs show connection errors | `docker-compose restart transaction-service` |
| Database unreachable | Transactions not saving | `docker-compose restart postgres` |
| Not logged in | 401 errors in console | Log in again |
| API Gateway down | Network errors in browser | `docker-compose restart api-gateway` |

---

## Still Not Working?

**Check the complete flow:**
```bash
# 1. All services running?
docker-compose ps

# 2. Check transaction service logs (most important)
docker-compose logs transaction-service | tail -50

# 3. Check API Gateway logs
docker-compose logs api-gateway | tail -30

# 4. Test API directly
curl http://localhost:3000/api/health
```

**If still stuck:** Share the output of `docker-compose logs transaction-service` - that's where the real error will be.

---

*Remember: Send Money requires RabbitMQ → Transaction Service → Database. If any link in this chain is broken, it won't work.*

