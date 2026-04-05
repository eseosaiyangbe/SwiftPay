# Why "Send Money" is Static and Unresponsive - Root Cause Analysis

> **Quick Analysis** of why the Send Money button might be static/unresponsive in Docker Compose

---

## Understanding the Button Behavior

Looking at the code, the Send Money button is **disabled** when:
1. `sendLoading` is `true` (stuck in loading state)
2. `!sendAmount` (no amount entered)
3. `!recipient` (no recipient selected)

The button is also **hidden** if:
- `wallet` is `null` (wallet not loaded)

---

## Most Likely Issues (In Order of Probability)

### 🔴 Issue #1: Wallet Not Loaded (Most Common)

**Symptom:** Send Money section doesn't appear at all, or button is disabled

**Why it happens:**
- Frontend can't load wallet data from API
- Error: "Failed to load wallet: connect ECONNREFUSED"
- Wallet service is down or unreachable

**Check:**
```bash
# Check wallet service
docker-compose ps wallet-service

# Check wallet service logs
docker-compose logs wallet-service | tail -20
```

**Fix:**
```bash
docker-compose restart wallet-service
```

**Code evidence:**
```javascript
{activeTab === 'send' && wallet && (  // ← Section only shows if wallet exists
  // Send Money UI here
)}
```

---

### 🔴 Issue #2: No Recipients Available

**Symptom:** Button is disabled, recipient dropdown is empty

**Why it happens:**
- `allWallets` is empty (no other users to send to)
- Frontend can't fetch list of wallets
- API Gateway can't reach wallet service

**Check:**
```bash
# Check if API Gateway can reach wallet service
docker-compose logs api-gateway | grep -i "wallet\|error" | tail -10

# Check wallet service
docker-compose ps wallet-service
```

**Fix:**
```bash
# Restart services
docker-compose restart wallet-service api-gateway
```

**Code evidence:**
```javascript
const otherUsers = allWallets.filter(u => u.user_id !== user.id);
// If allWallets is empty, otherUsers is empty, dropdown has no options
```

---

### 🔴 Issue #3: API Call Fails Silently (sendLoading Stuck)

**Symptom:** Button shows "Processing..." forever, never completes

**Why it happens:**
- API call to `/api/transactions` never completes (hangs)
- Network timeout
- API Gateway is down
- Transaction service is down
- RabbitMQ is down (transaction can't be queued)

**Check:**
```bash
# Check all critical services
docker-compose ps api-gateway transaction-service rabbitmq

# Check transaction service logs (most important)
docker-compose logs transaction-service | tail -30
```

**Fix:**
```bash
# Restart the chain
docker-compose restart rabbitmq
sleep 5
docker-compose restart transaction-service
docker-compose restart api-gateway
```

**Code evidence:**
```javascript
setSendLoading(true);  // ← Set to true when starting
try {
  await APIClient.createTransaction(...);  // ← If this hangs, loading stays true
} finally {
  setSendLoading(false);  // ← Only resets if try/catch completes
}
```

---

### 🟡 Issue #4: JavaScript Error (Button Click Does Nothing)

**Symptom:** Button appears enabled but clicking does nothing

**Why it happens:**
- JavaScript error in browser console
- `handleSendMoney` function throws error before API call
- Validation fails silently

**Check:**
1. Open browser console (F12)
2. Click Send Money button
3. Look for red error messages

**Common errors:**
- `Cannot read property 'id' of null` → User not logged in
- `wallet is null` → Wallet not loaded
- `Network error` → API Gateway unreachable

**Fix:**
- Fix the JavaScript error shown in console
- Refresh page and log in again
- Check if all services are running

---

### 🟡 Issue #5: CORS or Network Error

**Symptom:** Button works but shows "Transaction failed: Failed to fetch"

**Why it happens:**
- Frontend can't reach API Gateway
- CORS error (unlikely in Docker Compose)
- Network connectivity issue

**Check:**
```bash
# Test API Gateway from host
curl http://localhost:3000/api/health

# Check frontend nginx config
docker-compose exec frontend cat /etc/nginx/conf.d/default.conf | grep proxy_pass
```

**Fix:**
```bash
# Restart frontend and API Gateway
docker-compose restart frontend api-gateway
```

---

## Quick Diagnostic Flow

**Step 1: Check if Send Money section appears**
- If NO → Wallet not loaded (Issue #1)
- If YES → Continue

**Step 2: Check recipient dropdown**
- If EMPTY → No recipients available (Issue #2)
- If HAS OPTIONS → Continue

**Step 3: Fill form and click button**
- If NOTHING HAPPENS → JavaScript error (Issue #4)
- If "Processing..." FOREVER → API call stuck (Issue #3)
- If ERROR MESSAGE → Network/CORS issue (Issue #5)

---

## Most Common Root Cause

**In Docker Compose, the #1 issue is usually:**

**RabbitMQ is down or Transaction Service can't connect to RabbitMQ**

**Why:**
- Send Money creates a transaction
- Transaction Service tries to queue it in RabbitMQ
- If RabbitMQ is down, the API call hangs or fails
- Button appears stuck or shows error

**Quick check:**
```bash
docker-compose ps rabbitmq transaction-service
docker-compose logs transaction-service | grep -i "rabbitmq\|error" | tail -10
```

**Quick fix:**
```bash
docker-compose restart rabbitmq
sleep 10
docker-compose restart transaction-service
```

---

## Complete Diagnostic Command

Run this to check everything at once:

```bash
echo "=== Service Status ==="
docker-compose ps

echo ""
echo "=== RabbitMQ Status ==="
docker-compose logs rabbitmq | tail -5

echo ""
echo "=== Transaction Service (Last 10 lines) ==="
docker-compose logs transaction-service | tail -10

echo ""
echo "=== API Gateway (Last 5 lines) ==="
docker-compose logs api-gateway | tail -5

echo ""
echo "=== Wallet Service (Last 5 lines) ==="
docker-compose logs wallet-service | tail -5
```

**Look for:**
- Any service showing `Exit` or `Restarting`
- Error messages in logs
- Connection refused errors

---

## Summary: What Makes Send Money "Static"

1. **Button disabled** → Missing amount/recipient OR `sendLoading` stuck
2. **Button hidden** → Wallet not loaded
3. **Button does nothing** → JavaScript error OR API call fails silently
4. **Button stuck on "Processing"** → API call never completes (RabbitMQ/Transaction Service issue)

**Most likely:** RabbitMQ down or Transaction Service can't connect to RabbitMQ.

