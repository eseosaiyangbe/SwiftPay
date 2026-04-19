# How to Debug This System When Something Breaks

> **Phase 3 - Debugging & Operations** - Read this only when stuck. Reference doc, not onboarding.

> **Where you are in the path:** Structured weeks → [`LEARNING-PATH.md`](../LEARNING-PATH.md). Quick fixes → [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md). Validate: **MicroK8s** `./scripts/validate.sh --env k8s --host http://api.swiftpay.local`; **Compose** `./scripts/validate.sh`; **EKS** `./scripts/validate.sh --env cloud --host https://…`.

This document teaches you how to think about failures, not just how to run commands. Being wrong is part of the process.

---

## The Reality of Debugging

When something breaks, you'll feel lost. That's normal. Senior engineers feel lost too. The difference isn't knowledge - it's approach.

**Senior engineers:**
- Classify the failure (what type of problem is this?)
- Form hypotheses (what could cause this?)
- Test hypotheses systematically (check this, then that)
- Accept being wrong (most hypotheses are wrong)

**Beginners often:**
- Try random things (maybe this will work?)
- Read everything (surely the answer is here?)
- Give up (this is too hard)

This document teaches you the senior engineer approach.

---

## Failure Classification

Not all failures are the same. Classifying the failure tells you where to look.

### Type 1: Application Failure

**Symptoms:**
- Service returns 500 error
- Service crashes and restarts
- Service logs show exceptions

**What this means:**
- Code is broken
- Dependencies are missing
- Configuration is wrong

**Where to look:**
- Service logs: `kubectl logs -n swiftpay -l app=<service-name>`
- Recent code changes
- Environment variables

**Example:**
```
Transaction Service returns 500
→ Check logs: "Error: Cannot connect to database"
→ Hypothesis: Database connection string is wrong
→ Check: Environment variables in deployment
→ Fix: Correct DB_HOST value
```

### Type 2: Configuration Failure

**Symptoms:**
- Service can't start
- Service can't connect to dependencies
- Wrong behavior (but no errors)

**What this means:**
- Environment variables are wrong
- Service URLs are incorrect
- Network policies are blocking traffic

**Where to look:**
- Deployment YAML files
- ConfigMaps and Secrets
- Network policies

**Example:**
```
Wallet Service can't reach PostgreSQL
→ Check: Network policy allows traffic?
→ Check: Service name correct? (postgres vs postgresql)
→ Check: Port correct? (5432)
→ Fix: Update network policy or service name
```

### Type 3: Network Failure

**Symptoms:**
- Timeouts
- Connection refused errors
- Services can't reach each other

**What this means:**
- Service is down
- Network policy is blocking
- DNS resolution is failing
- Port is wrong

**Where to look:**
- Service status: `kubectl get pods -n swiftpay`
- Network policies: `kubectl get networkpolicies -n swiftpay`
- Service endpoints: `kubectl get endpoints -n swiftpay`

**Example:**
```
API Gateway can't reach Auth Service
→ Check: Is Auth Service running? (kubectl get pods)
→ Check: Can API Gateway resolve auth-service? (DNS)
→ Check: Network policy allows traffic?
→ Fix: Start service, fix DNS, or update network policy
```

### Type 4: State Failure

**Symptoms:**
- Data is missing
- Data is wrong
- Transactions are stuck

**What this means:**
- Database is corrupted
- Cache is stale
- Queue has old messages
- State is inconsistent

**Where to look:**
- Database: Query tables directly
- Redis: Check cached values
- RabbitMQ: Check queue depth
- Transaction status in database

**Example:**
```
Transaction stuck in PENDING
→ Check: Is there a message in RabbitMQ?
→ Check: Is worker running?
→ Check: Are there errors in worker logs?
→ Check: Database transaction status
→ Fix: Restart worker, clear queue, or manually update status
```

---

## How to Reason Using Logs

Logs tell you what happened. They don't tell you why. Your job is to figure out why.

### What Logs Tell You

**Service logs show:**
- What the service tried to do
- What error occurred
- When it happened
- Request IDs (for tracing)

**What logs don't show:**
- Why the error occurred (usually)
- What to do about it (usually)
- The full context (you need to piece it together)

### How to Read Logs

**1. Start with the error message**

```
Error: Connection timeout to wallet-service:3001
```

This tells you:
- What failed: Connection attempt
- Where it failed: wallet-service
- When it failed: After timeout period

**2. Look for patterns**

```
10:00:00 - Connection timeout
10:00:05 - Connection timeout
10:00:10 - Connection timeout
```

Pattern: Consistent failures. This suggests a systemic issue, not a one-off error.

**3. Check timestamps**

```
10:00:00 - Transaction created
10:00:01 - Message queued
10:00:02 - Worker started processing
10:05:00 - Still processing (stuck)
```

Timeline shows: Worker started but never finished. Something is blocking it.

**4. Follow request IDs**

```
[req-123] Transaction created
[req-123] Calling wallet service
[req-123] Error: Timeout
```

Request ID lets you trace one request across multiple services.

### What Signals to Trust

**Trust:**
- Error messages (they're usually accurate about what failed)
- Timestamps (they show sequence of events)
- Request IDs (they let you trace flows)

**Don't trust:**
- First error you see (might be a symptom, not the cause)
- Single log line (context matters)
- Your assumptions (verify everything)

### What Noise to Ignore

**Ignore:**
- Health check logs (they're just noise)
- Metrics collection logs (unless debugging metrics)
- Successful requests (focus on failures)

**Pay attention to:**
- Errors (obviously)
- Warnings (might indicate problems)
- Patterns (repeated errors suggest systemic issues)

---

## Hypothesis-Driven Debugging

Debugging is forming hypotheses and testing them. Most hypotheses will be wrong. That's fine.

### The Process

**1. Observe the symptom**

```
User reports: "Transaction failed"
```

**2. Form a hypothesis**

```
Hypothesis: Wallet Service is down
```

**3. Test the hypothesis**

```
Test: kubectl get pods -n swiftpay -l app=wallet-service
Result: Pods are running
Conclusion: Hypothesis is wrong
```

**4. Form a new hypothesis**

```
Hypothesis: Wallet Service can't reach database
Test: kubectl logs -n swiftpay -l app=wallet-service | grep -i "database\|postgres"
Result: "Connection refused to postgres:5432"
Conclusion: Hypothesis is correct
```

**5. Fix the issue**

```
Fix: Check network policy, check service name, check database is running
```

### Common Hypotheses (And How to Test Them)

**Hypothesis: Service is down**

Test: `kubectl get pods -n swiftpay -l app=<service-name>`

**Hypothesis: Service can't reach dependency**

Test: Check service logs for connection errors

**Hypothesis: Database is down**

Test: `kubectl get pods -n swiftpay -l app=postgres`

**Hypothesis: Network policy is blocking**

Test: `kubectl get networkpolicies -n swiftpay` and check rules

**Hypothesis: Configuration is wrong**

Test: `kubectl get deployment <service> -n swiftpay -o yaml` and check env vars

**Hypothesis: Queue is backing up**

Test: Check RabbitMQ management UI or `kubectl exec` into RabbitMQ pod

**Hypothesis: Cache is stale**

Test: Check Redis directly or clear cache and retry

### Being Wrong is Part of the Process

You'll form many wrong hypotheses. That's normal. Each wrong hypothesis eliminates a possibility and gets you closer to the answer.

**Example:**

```
Symptom: Transaction stuck in PENDING

Hypothesis 1: Worker is down
Test: kubectl get pods -l app=transaction-service
Result: Worker is running
Conclusion: Wrong, but we know worker isn't the issue

Hypothesis 2: RabbitMQ is down
Test: kubectl get pods -l app=rabbitmq
Result: RabbitMQ is running
Conclusion: Wrong, but we know RabbitMQ isn't the issue

Hypothesis 3: Message is in queue but worker isn't consuming
Test: Check RabbitMQ queue depth
Result: Queue is empty
Conclusion: Wrong, message was consumed

Hypothesis 4: Worker consumed message but crashed before processing
Test: Check worker logs for errors
Result: "Error: Cannot connect to wallet-service"
Conclusion: Correct! Worker can't reach Wallet Service
```

Each wrong hypothesis taught you something. That's progress.

---

## Debugging a Real Example

Let's debug a real issue: "User can't send money, gets 500 error"

### Step 1: Classify the Failure

**Symptom:** 500 error when sending money

**Classification:** Application failure (service is returning error)

**Where to start:** Check API Gateway logs (it's the entry point)

### Step 2: Check API Gateway Logs

```bash
kubectl logs -n swiftpay -l app=api-gateway --tail=50
```

**What we see:**
```
Error: Circuit breaker open for transaction-service-create
```

**What this tells us:**
- API Gateway tried to call Transaction Service
- Circuit breaker is open (Transaction Service has been failing)
- Request was rejected immediately

**New hypothesis:** Transaction Service is broken

### Step 3: Check Transaction Service Logs

```bash
kubectl logs -n swiftpay -l app=transaction-service --tail=50
```

**What we see:**
```
Error: Cannot connect to RabbitMQ
Connection timeout to rabbitmq:5672
```

**What this tells us:**
- Transaction Service can't reach RabbitMQ
- This is causing Transaction Service to fail
- Circuit breaker opened because of repeated failures

**New hypothesis:** RabbitMQ is down or unreachable

### Step 4: Check RabbitMQ Status

```bash
kubectl get pods -n swiftpay -l app=rabbitmq
```

**What we see:**
```
rabbitmq-xxx   1/1   Running
```

RabbitMQ is running. So why can't Transaction Service reach it?

**New hypothesis:** Network policy is blocking traffic

### Step 5: Check Network Policies

```bash
kubectl get networkpolicies -n swiftpay
kubectl describe networkpolicy <policy-name> -n swiftpay
```

**What we see:**
- Network policy exists
- Policy allows Transaction Service to connect to RabbitMQ
- But policy might not be applied correctly

**Test:** Check if Transaction Service pod has the right labels

```bash
kubectl get pods -n swiftpay -l app=transaction-service --show-labels
```

**What we see:**
```
Labels: app=transaction-service
```

Labels match. Network policy should work.

**New hypothesis:** DNS resolution is failing

### Step 6: Test DNS from Transaction Service Pod

```bash
kubectl exec -n swiftpay <transaction-service-pod> -- nslookup rabbitmq
```

**What we see:**
```
Server:    10.152.183.10
Address:   10.152.183.10#53

Name:      rabbitmq.swiftpay.svc.cluster.local
Address:   10.152.183.80
```

DNS works. RabbitMQ resolves correctly.

**New hypothesis:** Port is wrong or service is listening on wrong port

### Step 7: Check RabbitMQ Service Configuration

```bash
kubectl get svc rabbitmq -n swiftpay -o yaml
```

**What we see:**
```yaml
ports:
  - port: 5672
    targetPort: 5672
```

Port is correct.

**New hypothesis:** RabbitMQ isn't actually listening (even though pod is running)

### Step 8: Check RabbitMQ Logs

```bash
kubectl logs -n swiftpay -l app=rabbitmq --tail=50
```

**What we see:**
```
Error: Disk space low
RabbitMQ shutting down
```

**Found it!** RabbitMQ is shutting down due to low disk space.

**Fix:** Free up disk space or increase PVC size

---

## What This Example Teaches

**1. Start at the symptom, not the solution**

We didn't know it was a disk space issue. We worked backward from the error.

**2. Each hypothesis eliminated possibilities**

- Service down? No.
- Network policy? No.
- DNS? No.
- Port? No.
- Actually listening? No - found the real issue.

**3. Logs are your friend**

The answer was in RabbitMQ logs. We just had to check them.

**4. Being systematic helps**

We checked things in order: API Gateway → Transaction Service → RabbitMQ → Network → DNS → Ports → Logs

**5. The last thing you check is often the answer**

Disk space was the last thing we checked. That's normal.

---

## Common Failure Patterns

### Pattern 1: Service Can't Reach Dependency

**Symptoms:**
- Connection timeout errors
- "Service unavailable" errors
- Circuit breaker opens

**What to check:**
1. Is dependency running? (`kubectl get pods`)
2. Can service resolve DNS? (`kubectl exec ... nslookup`)
3. Is network policy blocking? (`kubectl get networkpolicies`)
4. Is port correct? (Check service YAML)
5. Is dependency actually listening? (Check dependency logs)

### Pattern 2: Transaction Stuck

**Symptoms:**
- Transaction stays in PENDING
- User money is "stuck"
- No errors in logs

**What to check:**
1. Is transaction in database? (Query transactions table)
2. Is message in RabbitMQ queue? (Check queue depth)
3. Is worker running? (`kubectl get pods`)
4. Are there worker errors? (Check worker logs)
5. Is Wallet Service reachable? (Check from worker pod)

### Pattern 3: Rate Limiting Issues

**Symptoms:**
- 429 Too Many Requests errors
- Some requests work, others don't

**What to check:**
1. What's the rate limit? (Check API Gateway code)
2. How many requests is IP making? (Check Redis)
3. Is rate limiter working? (Check API Gateway logs)
4. Is Redis working? (`kubectl get pods -l app=redis`)

### Pattern 4: Data Inconsistency

**Symptoms:**
- Balances don't match
- Transactions missing
- Duplicate transactions

**What to check:**
1. Query database directly (see actual state)
2. Check transaction logs (see what happened)
3. Check idempotency keys in Redis (see if duplicates were caught)
4. Check for failed database transactions (rollbacks)

---

## What to Do When You're Stuck

**1. Take a break**

Seriously. Stepping away helps. When you come back, you'll see things you missed.

**2. Explain the problem to someone (or yourself)**

The act of explaining forces you to organize your thoughts. Often, you'll realize the answer while explaining.

**3. Start over with fresh eyes**

Go back to the symptom. Trace it again. You might have missed something.

**4. Check the basics**

- Are services running?
- Can they reach dependencies?
- Are environment variables set?
- Are network policies correct?

Often, the issue is something simple you overlooked.

**5. Look at the code**

The code is the source of truth. If logs say one thing but code says another, trust the code.

**6. Ask for help (with context)**

When asking for help, provide:
- What you're trying to do
- What error you're seeing
- What you've already checked
- What your hypothesis is

This helps others help you faster.

---

## Key Takeaways

1. **Classify failures** - Application, configuration, network, or state
2. **Form hypotheses** - What could cause this?
3. **Test systematically** - Check one thing at a time
4. **Trust logs** - But verify with code
5. **Being wrong is normal** - Each wrong hypothesis teaches you something
6. **Start simple** - Check basics before complex solutions
7. **Take breaks** - Fresh eyes see things you missed

**The goal isn't to never get stuck.**

The goal is to know how to get unstuck. That's a skill. Like any skill, it improves with practice.

---

*Debugging is reasoning. The more you practice reasoning about failures, the better you get at it. Start with one failure. Understand it completely. Then move to the next.*

