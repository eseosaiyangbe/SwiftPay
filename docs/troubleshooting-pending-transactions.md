# Troubleshooting: Pending Transactions Not Auto-Reversing

> **Issue Date**: January 13, 2026  
> **Severity**: High - User funds stuck in pending state  
> **Status**: ✅ Resolved (Manual process documented)

---

## Table of Contents
1. [Problem Summary](#problem-summary)
2. [Root Cause Analysis](#root-cause-analysis)
3. [How We Diagnosed It](#how-we-diagnosed-it)
4. [The Fix](#the-fix)
5. [Database Access Methods](#database-access-methods)
6. [Prevention & Monitoring](#prevention--monitoring)
7. [Manual Recovery Process](#manual-recovery-process)

---

## Problem Summary

### **Symptom**
SwiftPay dashboard showed **1 Pending transaction** that had been stuck for **4 days** (since January 9, 2026).

### **Expected Behavior**
The `transaction-timeout-handler` CronJob should automatically reverse any transaction stuck in PENDING status for more than 1 minute.

### **Actual Behavior**
Transactions were staying in PENDING state indefinitely, blocking user funds.

### **Impact**
- User funds locked in pending transactions
- Cannot retry failed transactions
- Poor user experience
- Potential loss of trust in the platform

---

## Root Cause Analysis

We discovered **three cascading issues**:

### **Issue 1: CronJob Not Initially Deployed**
```bash
kubectl get cronjobs -n swiftpay
# Expected: transaction-timeout-handler
# Actual: Not found (only image-scanning and postgres-backup)
```

**Root Cause**: The `transaction-timeout-handler.yaml` file existed in the repo but was never applied to the cluster during initial deployment.

---

### **Issue 2: Missing Resource Requests/Limits**
```bash
kubectl describe job transaction-timeout-handler-29472082 -n swiftpay
```

**Error Message**:
```
Error creating: pods "transaction-timeout-handler-29472082-m82g9" is forbidden: 
failed quota: swiftpay-resource-quota: must specify limits.cpu for: transaction-timeout-container; 
limits.memory for: transaction-timeout-container; 
requests.cpu for: transaction-timeout-container; 
requests.memory for: transaction-timeout-container
```

**Root Cause**: The CronJob YAML didn't include `resources` section, which is **required** when a ResourceQuota is active in the namespace.

**Why This Matters**: 
- We have a `swiftpay-resource-quota` that limits total cluster resources
- Every pod MUST declare how much CPU/memory it needs
- Without this, Kubernetes rejects pod creation
- This is a **production best practice** to prevent resource exhaustion

---

### **Issue 3: DNS Resolution Failure in Job Pods**
```bash
kubectl logs job/fix-pending-test -n swiftpay
```

**Error Message**:
```
Testing DNS resolution...
;; connection timed out; no servers could be reached
DNS lookup failed
Attempting connection to postgres...
psql: error: could not translate host name "postgres.swiftpay.svc.cluster.local" to address: Try again
```

**Root Cause**: Job pods couldn't resolve DNS names to reach the PostgreSQL service.

**Possible Causes**:
1. **Network Policies**: May be blocking DNS traffic (port 53 UDP/TCP)
2. **DNS Configuration**: Job pods not using CoreDNS properly
3. **Headless Service**: PostgreSQL uses `clusterIP: None`, requiring StatefulSet-specific DNS

**Why This Is Tricky**:
- Other pods (transaction-service, auth-service) can connect to postgres fine
- Job pods are short-lived and may have different DNS behavior
- The postgres service is a **Headless Service** which uses different DNS patterns

---

## How We Diagnosed It

### **Step 1: Check Pending Transactions in Dashboard**
```
Dashboard showed: Pending: 1, Failed: 5, Completed: 3
```

### **Step 2: Verify CronJob Existence**
```bash
kubectl get cronjobs -n swiftpay
```

**Result**: `transaction-timeout-handler` was missing initially, then found but not running successfully.

---

### **Step 3: Check Job Execution History**
```bash
kubectl get jobs -n swiftpay | grep timeout
```

**Result**: 
```
transaction-timeout-handler-29472078   Running    0/1    4m20s
transaction-timeout-handler-29472079   Running    0/1    3m20s
transaction-timeout-handler-29472080   Running    0/1    2m20s
... (all stuck in Running state)
```

**Analysis**: Jobs were being created every minute (per schedule) but none were completing.

---

### **Step 4: Describe Failed Job**
```bash
kubectl describe job transaction-timeout-handler-29472082 -n swiftpay
```

**Key Finding**:
```
Events:
  Warning  FailedCreate  Error creating: pods ... is forbidden: 
  failed quota: swiftpay-resource-quota: must specify limits.cpu, limits.memory, 
  requests.cpu, requests.memory for: transaction-timeout-container
```

---

### **Step 5: Add Resources, Deploy, Test**
After adding resources, jobs started but failed with DNS errors:
```bash
kubectl logs job/fix-pending-final -n swiftpay
```

**Output**:
```
psql: error: could not translate host name "postgres" to address: Try again
```

---

### **Step 6: Database Direct Access (The Solution)**
Since the CronJob couldn't reach postgres, we accessed the database **directly from within the postgres pod**:

```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, from_user_id, amount, status, created_at 
   FROM transactions 
   WHERE status = 'PENDING' 
   ORDER BY created_at DESC;"
```

**Result**: Found 3 stuck transactions:
```
TXN-1767960889359-D8WG8W41M | PENDING | 2026-01-09 12:14:49 (4 days old!)
TXN-1768327650257-7SWKV7A18 | PENDING | 2026-01-13 18:07:30 (recent)
TXN-1768327668403-UEYP5STTV | PENDING | 2026-01-13 18:07:48 (recent)
```

---

## The Fix

### **Temporary Fix: Manual SQL Execution**
Executed the timeout logic directly inside the postgres pod:

```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "UPDATE transactions 
   SET 
     status = 'FAILED',
     error_message = 'Transaction timeout - manually reversed',
     completed_at = CURRENT_TIMESTAMP,
     processing_started_at = COALESCE(processing_started_at, created_at)
   WHERE 
     status = 'PENDING' 
     AND created_at < NOW() - INTERVAL '1 minute';"
```

**Result**: `UPDATE 3` (all pending transactions reversed)

---

### **Permanent Fix Attempts**

#### **Attempt 1: Add Resource Limits** ✅
```yaml
resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "100m"
    memory: "128Mi"
```

**Status**: Fixed resource quota issue, but DNS still broken.

#### **Attempt 2: Try Different DNS Names** ❌
Tried:
- `postgres` → Failed
- `postgres-0.postgres` → Failed
- `postgres-0.postgres.swiftpay.svc.cluster.local` → Failed
- `postgres.swiftpay.svc.cluster.local` → Failed

**Status**: All DNS lookups failed.

#### **Attempt 3: Suspend CronJob** ✅
```bash
kubectl patch cronjob transaction-timeout-handler -n swiftpay -p '{"spec":{"suspend":true}}'
```

**Status**: Prevented failed jobs from accumulating and hitting pod quota.

---

## Database Access Methods

### **Method 1: Direct Pod Access (Most Reliable)**
This is what we used to fix the issue. You're executing commands **inside** the postgres pod:

```bash
# Basic query
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "SELECT NOW();"

# Check pending transactions
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, status, created_at, NOW() - created_at as age 
   FROM transactions 
   WHERE status = 'PENDING' 
   ORDER BY created_at DESC;"

# Count transactions by status
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT status, COUNT(*) as count 
   FROM transactions 
   GROUP BY status;"

# Check specific transaction
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT * FROM transactions WHERE id = 'TXN-...';"
```

**When to Use**: 
- ✅ Network policies blocking external access
- ✅ DNS issues preventing service discovery
- ✅ Quick troubleshooting
- ✅ Emergency fixes

---

### **Method 2: Interactive psql Session**
For more complex queries, open an interactive session:

```bash
# Open psql shell
kubectl exec -it postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay

# Inside psql:
swiftpay=# \dt                          -- List all tables
swiftpay=# \d transactions              -- Describe transactions table
swiftpay=# SELECT * FROM transactions LIMIT 5;
swiftpay=# \q                           -- Quit
```

**When to Use**: 
- ✅ Multiple queries
- ✅ Exploring schema
- ✅ Complex troubleshooting
- ✅ Learning the database structure

---

### **Method 3: Port Forwarding (Local Access)**
Access the database from your laptop as if it were local:

```bash
# Forward postgres port to your laptop
kubectl port-forward postgres-0 5432:5432 -n swiftpay

# In another terminal, connect with local psql
psql -h localhost -U swiftpay -d swiftpay -p 5432

# Or use a GUI tool like pgAdmin, DBeaver, etc.
# Host: localhost
# Port: 5432
# User: swiftpay
# Database: swiftpay
```

**When to Use**: 
- ✅ GUI database tools
- ✅ Complex data analysis
- ✅ Exporting data
- ✅ Long troubleshooting sessions

---

### **Method 4: Service Connection (From Another Pod)**
Create a temporary pod to test service connectivity:

```bash
# Create a test pod with psql
kubectl run psql-test --rm -it --image=postgres:15-alpine -n swiftpay -- sh

# Inside the pod:
psql -h postgres.swiftpay.svc.cluster.local -U swiftpay -d swiftpay
```

**When to Use**: 
- ✅ Testing DNS resolution
- ✅ Testing network policies
- ✅ Debugging service discovery issues

---

## Database Credentials

### **Get Database Username**
```bash
kubectl get secret db-secrets -n swiftpay -o jsonpath='{.data.DB_USER}' | base64 -d
# Output: swiftpay
```

### **Get Database Password**
```bash
kubectl get secret db-secrets -n swiftpay -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### **Get Database Name**
```bash
kubectl get configmap app-config -n swiftpay -o jsonpath='{.data.DB_NAME}'
# Output: swiftpay
```

### **Full Connection String**
```bash
# From inside cluster
postgres://swiftpay:<password>@postgres:5432/swiftpay

# Full DNS name
postgres://swiftpay:<password>@postgres.swiftpay.svc.cluster.local:5432/swiftpay
```

---

## Prevention & Monitoring

### **Check for Pending Transactions**
Create an alias for quick checks:

```bash
alias check-pending='kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "SELECT COUNT(*) as pending_count FROM transactions WHERE status = '\''PENDING'\'' AND created_at < NOW() - INTERVAL '\''1 minute'\'';"'

# Usage
check-pending
```

---

### **Set Up Alerting**
Create a monitoring script:

```bash
#!/bin/bash
# check-stuck-transactions.sh

PENDING_COUNT=$(kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -t -c \
  "SELECT COUNT(*) FROM transactions WHERE status = 'PENDING' AND created_at < NOW() - INTERVAL '1 minute';")

if [ "$PENDING_COUNT" -gt 0 ]; then
  echo "⚠️  WARNING: $PENDING_COUNT stuck transactions found!"
  # Send to Slack/email/PagerDuty here
  exit 1
else
  echo "✅ No stuck transactions"
  exit 0
fi
```

Run this as a Kubernetes CronJob or external monitoring.

---

### **Dashboard Metrics**
Add a Prometheus metric to track pending transaction age:

```javascript
// In transaction-service
const pendingTransactionAge = new prometheus.Gauge({
  name: 'swiftpay_pending_transaction_max_age_seconds',
  help: 'Age of oldest pending transaction in seconds',
});

// Update every minute
setInterval(async () => {
  const oldest = await db.query(`
    SELECT EXTRACT(EPOCH FROM (NOW() - created_at)) as age_seconds
    FROM transactions 
    WHERE status = 'PENDING' 
    ORDER BY created_at ASC 
    LIMIT 1
  `);
  
  if (oldest.rows[0]) {
    pendingTransactionAge.set(oldest.rows[0].age_seconds);
  }
}, 60000);
```

Alert when `swiftpay_pending_transaction_max_age_seconds > 60` (1 minute).

---

## Manual Recovery Process

### **Step 1: Check for Stuck Transactions**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, from_user_id, to_user_id, amount, status, 
          created_at, NOW() - created_at as age 
   FROM transactions 
   WHERE status = 'PENDING' 
   ORDER BY created_at DESC;"
```

---

### **Step 2: Review Before Reversing**
**IMPORTANT**: Check why they're stuck:
- Is RabbitMQ down?
- Is the transaction-service-worker pod running?
- Are there wallet service errors?

```bash
# Check RabbitMQ
kubectl get pods -n swiftpay | grep rabbitmq

# Check transaction service
kubectl logs -n swiftpay deployment/transaction-service --tail=50

# Check RabbitMQ queues
kubectl exec -it rabbitmq-xxx -n swiftpay -- rabbitmqctl list_queues
```

---

### **Step 3: Reverse Stuck Transactions**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "UPDATE transactions 
   SET 
     status = 'FAILED',
     error_message = 'Transaction timeout - manually reversed by admin at ' || NOW(),
     completed_at = CURRENT_TIMESTAMP,
     processing_started_at = COALESCE(processing_started_at, created_at)
   WHERE 
     status = 'PENDING' 
     AND created_at < NOW() - INTERVAL '1 minute'
   RETURNING id, from_user_id, amount;"
```

The `RETURNING` clause shows you which transactions were reversed.

---

### **Step 4: Verify**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT status, COUNT(*) as count 
   FROM transactions 
   GROUP BY status;"
```

**Expected**:
```
  status   | count 
-----------+-------
 COMPLETED |    50
 FAILED    |    10
 PENDING   |     0  ← Should be zero!
```

---

### **Step 5: Check User Balances**
Make sure the wallet service properly handled the reversals:

```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT user_id, balance 
   FROM wallets 
   WHERE user_id IN (
     SELECT from_user_id FROM transactions 
     WHERE error_message LIKE '%manually reversed%'
   );"
```

**Verify**: User balances should reflect the failed transaction (funds returned).

---

## Common Transaction Issues

### **Issue: High PENDING Count**
```sql
SELECT COUNT(*) FROM transactions WHERE status = 'PENDING';
```

**Possible Causes**:
1. RabbitMQ connection issues
2. Transaction worker pods crashed
3. Wallet service unavailable
4. Database deadlocks

**Diagnosis**:
```bash
# Check RabbitMQ connectivity
kubectl exec transaction-service-xxx -n swiftpay -- wget -qO- http://rabbitmq:15672/api/aliveness-test/%2F

# Check worker pods
kubectl get pods -n swiftpay | grep transaction

# Check wallet service
kubectl get pods -n swiftpay | grep wallet
```

---

### **Issue: High FAILED Count**
```sql
SELECT error_message, COUNT(*) as count 
FROM transactions 
WHERE status = 'FAILED' 
GROUP BY error_message 
ORDER BY count DESC;
```

**Common Error Messages**:
- `"Insufficient funds"` → User tried to send more than they have (expected)
- `"Wallet service temporarily unavailable"` → Wallet service down
- `"Transaction timeout"` → Processing took too long
- `"Network timeout"` → RabbitMQ or service communication failure

---

### **Issue: No COMPLETED Transactions**
**This is a critical issue** - means the entire transaction processing pipeline is broken.

**Diagnosis Checklist**:
```bash
# 1. Check RabbitMQ is running
kubectl get pods -n swiftpay | grep rabbitmq

# 2. Check transaction service is running
kubectl get pods -n swiftpay | grep transaction

# 3. Check wallet service is running
kubectl get pods -n swiftpay | grep wallet

# 4. Check RabbitMQ logs for connection errors
kubectl logs rabbitmq-xxx -n swiftpay --tail=50

# 5. Check if messages are stuck in queue
kubectl exec rabbitmq-xxx -n swiftpay -- rabbitmqctl list_queues name messages consumers

# 6. Check transaction service logs for errors
kubectl logs deployment/transaction-service -n swiftpay --tail=100 | grep -i error
```

---

## Lessons Learned

### **1. Always Define Resources in Production**
Every container MUST have:
```yaml
resources:
  requests:    # Minimum guaranteed
    cpu: "50m"
    memory: "64Mi"
  limits:      # Maximum allowed
    cpu: "100m"
    memory: "128Mi"
```

---

### **2. Test CronJobs Separately**
Don't assume CronJobs work like Deployments. Test manually:
```bash
kubectl create job --from=cronjob/my-cronjob test-job -n swiftpay
kubectl logs job/test-job -n swiftpay
```

---

### **3. DNS in Job Pods Can Behave Differently**
Job pods are short-lived and may have different:
- DNS caching behavior
- Network policy evaluation
- Service discovery patterns

Always test DNS from Job pods specifically.

---

### **4. Have a Manual Fallback**
When automation fails, you need a **quick, tested manual process**.

Document it, test it, make it copy-paste ready.

---

### **5. Headless Services Are Special**
PostgreSQL uses `clusterIP: None` (headless service).

DNS resolution:
- ✅ `postgres` works from other pods in same namespace
- ✅ `postgres-0.postgres` works for StatefulSet pod 0
- ❌ May not work from Job pods (as we discovered)

**Best Practice**: Use the service name, not individual pod names.

---

## Next Steps

### **Option 1: Keep Manual Process**
- Document the recovery procedure (✅ Done)
- Set up monitoring to alert when stuck transactions occur
- Train team on manual recovery process

**Pros**: 
- Works immediately
- No complex debugging needed
- Full control over when/how reversal happens

**Cons**: 
- Requires manual intervention
- Not truly automated
- Doesn't scale if transaction volume increases

---

### **Option 2: Fix CronJob DNS**
Investigate and resolve the DNS issue:

1. **Check Network Policies**
   ```bash
   kubectl get networkpolicies -n swiftpay
   ```
   Ensure DNS traffic (port 53 UDP/TCP) is allowed from Job pods.

2. **Test DNS from Job Pod**
   ```bash
   kubectl run dns-test --rm -it --image=busybox -n swiftpay -- nslookup postgres
   ```

3. **Alternative: Use Init Container**
   Have the Job pod test DNS before running psql.

4. **Alternative: Use Kubernetes Job with kubectl**
   Instead of psql client, use kubectl from within the cluster.

---

### **Option 3: Move Logic to Transaction Service**
Instead of an external CronJob, add timeout logic to transaction-service:

```javascript
// In transaction-service/server.js
setInterval(async () => {
  await pool.query(`
    UPDATE transactions 
    SET status = 'FAILED', 
        error_message = 'Transaction timeout',
        completed_at = CURRENT_TIMESTAMP 
    WHERE status = 'PENDING' 
      AND created_at < NOW() - INTERVAL '1 minute'
  `);
}, 60000); // Every minute
```

**Pros**: 
- No DNS issues (runs in same pod as app)
- Simpler deployment
- Uses existing database connection

**Cons**: 
- Couples timeout logic to transaction service
- Less separation of concerns
- Harder to test independently

---

## Quick Reference

### **Check Pending Count**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT COUNT(*) FROM transactions WHERE status = 'PENDING';"
```

### **Reverse Stuck Transactions**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "UPDATE transactions SET status = 'FAILED', error_message = 'Transaction timeout - manually reversed', completed_at = CURRENT_TIMESTAMP WHERE status = 'PENDING' AND created_at < NOW() - INTERVAL '1 minute';"
```

### **View Recent Transactions**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, status, created_at FROM transactions ORDER BY created_at DESC LIMIT 10;"
```

### **Check CronJob Status**
```bash
kubectl get cronjob transaction-timeout-handler -n swiftpay
kubectl get jobs -n swiftpay | grep timeout
```

---

## Deep Dive: Complete CronJob Troubleshooting Journey

> **Date**: January 14, 2026  
> **Issue**: CronJob pods failing with DNS and connection errors  
> **Resolution Time**: ~2 hours  
> **Final Status**: ✅ Fully Automated - CronJob runs every minute

This section documents the **complete troubleshooting process** from initial DNS errors to final resolution. It shows the **diagnostic methodology**, **commands used**, and **lessons learned**.

---

### **Phase 1: Initial Investigation - CronJob Not Working**

#### **Symptom**
After deploying the CronJob, jobs were being created but never completing:
```bash
kubectl get jobs -n swiftpay | grep transaction-timeout
# Output: Multiple jobs showing Running 0/1, never completing
```

#### **Step 1.1: Check CronJob Events**
```bash
kubectl describe cronjob transaction-timeout-handler -n swiftpay
```

**What we found:**
```
Warning  FailedCreate  Error creating: pods ... exceeded quota: swiftpay-resource-quota: 
must specify limits.cpu for: transaction-timeout-container; 
limits.memory for: transaction-timeout-container
```

**Why this command?** 
- `describe` shows events and error messages that `get` doesn't show
- Events are ordered chronologically, helping trace the failure timeline

**Root Cause #1**: Missing resource requests/limits in CronJob spec

**Fix #1**: Added resources to CronJob container
```yaml
# k8s/jobs/transaction-timeout-handler.yaml
resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "100m"
    memory: "128Mi"
```

**Apply the fix:**
```bash
kubectl delete cronjob transaction-timeout-handler -n swiftpay
kubectl apply -f k8s/jobs/transaction-timeout-handler.yaml
```

**Why delete first?** CronJobs don't hot-reload resource changes - must recreate.

---

### **Phase 2: DNS Resolution Failures**

#### **Symptom**
After fixing resources, jobs were still failing. Checking pod logs:
```bash
# Get a job pod name
kubectl get pods -n swiftpay | grep transaction-timeout

# Check its logs
kubectl logs transaction-timeout-handler-29472463-j5gcj -n swiftpay
```

**Output:**
```
psql: error: could not translate host name "postgres.swiftpay.svc.cluster.local" to address: Try again
```

**Why this command?**
- Pod logs show the actual error from inside the container
- DNS errors appear here, not in events

#### **Step 2.1: Check CoreDNS Health**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**Output:**
```
NAME                       READY   STATUS    RESTARTS      AGE
coredns-79b94494c7-rt9xm   1/1     Running   4 (32h ago)   6d20h
```

**Why this command?** Verify CoreDNS is running (it's the DNS server for the cluster)

#### **Step 2.2: Check CoreDNS Logs for Errors**
```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

**Critical finding:**
```
[ERROR] plugin/kubernetes: Failed to watch *v1.Namespace: 
  Get "https://10.152.183.1:443/api/v1/namespaces?...": 
  http2: client connection lost
[WARNING] plugin/health: Local health request failed: context deadline exceeded
```

**Root Cause #2**: CoreDNS had lost connection to the Kubernetes API server

**Why this matters:**
- CoreDNS needs to watch Services to provide DNS resolution
- When it loses API connection, it can't update DNS records
- Long-running pods cached DNS before CoreDNS broke
- Short-lived Job pods never got DNS records

**Fix #2**: Restart CoreDNS
```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

**Wait for restart:**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
# Wait for STATUS: Running, READY: 1/1
```

**Verify healthy logs:**
```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
```

**Expected output (healthy):**
```
.:53
[INFO] plugin/reload: Running configuration SHA512 = ...
CoreDNS-1.10.1
linux/amd64, go1.20, 055b2c3
```

**Why delete the pod?**
- CoreDNS is managed by a Deployment
- Deleting the pod forces Kubernetes to create a fresh one
- Fresh pod re-establishes API server connection
- No downtime (new pod starts before old one fully terminates)

---

### **Phase 3: Still Failing After CoreDNS Fix**

#### **Symptom**
After CoreDNS restart, jobs still failing with DNS errors:
```bash
kubectl logs transaction-timeout-handler-29472480-cxkj8 -n swiftpay
# Output: psql: error: could not translate host name "postgres" to address: Try again
```

**Confusion:** CoreDNS is healthy, why still DNS errors?

#### **Step 3.1: Check Network Policies**
```bash
kubectl get networkpolicies -n swiftpay
```

**Output:**
```
NAME                                              POD-SELECTOR
default-deny-all                                  <none>
cronjob-allow-dns-and-db                          cronjob=transaction-timeout-handler
databases-allow-ingress-from-services             app in (postgres,redis,rabbitmq)
...
```

**Why this command?** Network policies can block network traffic even if DNS works

#### **Step 3.2: Examine CronJob Egress Policy**
```bash
kubectl describe networkpolicy cronjob-allow-dns-and-db -n swiftpay
```

**Output showed:**
```yaml
Egress:
  To:
    - NamespaceSelector: kubernetes.io/metadata.name=kube-system  # CoreDNS
    - PodSelector: app=postgres  # PostgreSQL
```

**This looked correct!** Egress (outbound) from CronJob → postgres was allowed.

#### **Step 3.3: Examine PostgreSQL Ingress Policy**
```bash
kubectl describe networkpolicy databases-allow-ingress-from-services -n swiftpay
```

**Critical finding:**
```yaml
Ingress:
  From:
    - PodSelector:
        app in (auth-service, wallet-service, transaction-service, notification-service)
```

**Root Cause #3**: PostgreSQL ingress policy only allowed backend services, NOT CronJob pods!

**Why this matters:**
- Network policies are **bidirectional** - both ends must allow traffic
- CronJob had **egress** (outbound) to postgres ✅
- Postgres had **NO ingress** (inbound) from CronJob ❌
- TCP connection requires both directions

**Analogy**: You can dial a phone number (egress), but if they block your number (no ingress), call fails.

**Fix #3**: Add CronJob to postgres ingress policy
```yaml
# k8s/policies/network-policies.yaml
# Under databases-allow-ingress-from-services
ingress:
  # Existing backend services
  - from:
    - podSelector:
        matchExpressions:
        - key: app
          operator: In
          values:
          - auth-service
          - wallet-service
          - transaction-service
          - notification-service
    ports:
    - protocol: TCP
      port: 5432
  
  # NEW: Allow CronJob pods
  - from:
    - podSelector:
        matchLabels:
          cronjob: transaction-timeout-handler
    ports:
    - protocol: TCP
      port: 5432
```

**Apply the fix:**
```bash
kubectl apply -f k8s/policies/network-policies.yaml
```

**Verify application:**
```bash
kubectl describe networkpolicy databases-allow-ingress-from-services -n swiftpay | grep -A 5 "Ingress"
```

**Unsuspend CronJob:**
```bash
kubectl patch cronjob transaction-timeout-handler -n swiftpay -p '{"spec":{"suspend":false}}'
```

---

### **Phase 4: Verification & Testing**

#### **Step 4.1: Wait for Job Execution**
```bash
echo "Waiting for CronJob execution..." && sleep 70
kubectl get jobs -n swiftpay -l cronjob=transaction-timeout-handler --sort-by=.metadata.creationTimestamp | tail -5
```

**Output (SUCCESS!):**
```
NAME                                   STATUS     COMPLETIONS   DURATION   AGE
transaction-timeout-handler-29472529   Complete   1/1           11s        106s
transaction-timeout-handler-29472530   Complete   1/1           8s         102s
transaction-timeout-handler-29472531   Complete   1/1           9s         42s
```

**Why this command?**
- `sleep 70` waits for next minute (CronJob schedule is `* * * * *`)
- `--sort-by` orders by creation time (newest last)
- `tail -5` shows most recent jobs

#### **Step 4.2: Check Job Logs**
```bash
kubectl logs job/transaction-timeout-handler-29472531 -n swiftpay
```

**Output:**
```
UPDATE 0
 reversed_count 
----------------
              0
(1 row)
```

**What this means:**
- `UPDATE 0` = No pending transactions (none needed reversing)
- `reversed_count: 0` = No transactions reversed in last minute
- SQL executed successfully with no errors

#### **Step 4.3: Verify Database**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT COUNT(*) as pending_count FROM transactions WHERE status = 'PENDING';"
```

**Output:**
```
 pending_count 
---------------
             0
(1 row)
```

#### **Step 4.4: End-to-End Test**
Create a test pending transaction to verify auto-reversal:

**Create old pending transaction:**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "INSERT INTO transactions (id, from_user_id, to_user_id, amount, status, created_at) 
   VALUES ('TEST-PENDING-' || floor(random() * 10000)::text, 'test-user-1', 'test-user-2', 
           100.00, 'PENDING', NOW() - INTERVAL '5 minutes');"
```

**Why NOW() - INTERVAL '5 minutes'?**
- Creates a transaction that's already 5 minutes old
- CronJob reverses transactions older than 1 minute
- Should be reversed in next run (within 60 seconds)

**Wait for CronJob:**
```bash
echo "Waiting for CronJob to reverse it..." && sleep 70
```

**Check if reversed:**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, status, error_message FROM transactions WHERE id LIKE 'TEST-PENDING%';"
```

**Output (SUCCESS!):**
```
        id         | status |                                     error_message                                      
-------------------+--------+----------------------------------------------------------------------------------------
 TEST-PENDING-9288 | FAILED | Transaction timeout - automatically reversed by system (2026-01-14 01:00:06.897898+00)
```

**Cleanup test data:**
```bash
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "DELETE FROM transactions WHERE id LIKE 'TEST-PENDING%';"
```

---

### **Phase 5: Additional Fixes**

#### **Issue 4: SQL Comment Syntax Errors**

While testing, logs showed:
```
ERROR:  syntax error at or near "#"
LINE 1: # ============================================
```

**Root Cause #4**: PostgreSQL uses `--` for comments, not `#`

**Fix #4**: Updated SQL comments in CronJob YAML
```yaml
# Changed from:
WHERE status = 'FAILED'  # Only failed transactions

# To:
WHERE status = 'FAILED'  -- Only failed transactions
```

**Why this matters:**
- `#` is valid in shell/YAML comments
- Inside `<< EOF` heredoc, everything is passed to psql
- PostgreSQL only recognizes `--` for SQL comments
- Wrong syntax causes query to fail

#### **Issue 5: Resource Quota Hit**

While troubleshooting, we hit pod limit:
```
Error creating: pods "..." is forbidden: exceeded quota: swiftpay-resource-quota, 
requested: pods=1, used: pods=20, limited: pods=20
```

**Fix #5**: Increased pod quota
```yaml
# k8s/policies/resource-quotas.yaml
spec:
  hard:
    pods: "30"  # Increased from 20
```

**Apply:**
```bash
kubectl apply -f k8s/policies/resource-quotas.yaml
```

**Why this matters:**
- CronJob creates new pod every minute
- Old pods stick around (for history)
- Eventually hit quota
- Kubernetes has `successfulJobsHistoryLimit: 3` but that's per job, not total

---

### **Final Architecture: What We Have Now**

#### **Network Policy Setup**
```
┌─────────────────────────────────────────────────────────┐
│  CronJob Pod (transaction-timeout-handler)              │
│  Label: cronjob=transaction-timeout-handler             │
└────────────────┬────────────────────────────────────────┘
                 │
                 │ Egress (outbound)
                 │ Allowed by: cronjob-allow-dns-and-db
                 │
                 ├──────────> DNS Query to CoreDNS (kube-system)
                 │            Port: 53 UDP/TCP
                 │
                 └──────────> PostgreSQL Connection
                              Port: 5432 TCP
                              ↓
                 ┌────────────┴────────────────────────────┐
                 │  PostgreSQL Pod (postgres-0)            │
                 │  Label: app=postgres                    │
                 │                                         │
                 │  Ingress (inbound) allowed from:        │
                 │  - Backend services                     │
                 │  - CronJob pods ← CRITICAL FIX          │
                 └─────────────────────────────────────────┘
```

#### **CronJob Execution Flow**
```
Every Minute:
  1. Kubernetes creates Job from CronJob template
  2. Job creates Pod with label: cronjob=transaction-timeout-handler
  3. Pod starts postgres:15-alpine container
  4. Container runs: psql -h postgres -U swiftpay -d swiftpay << EOF
  5. DNS: Resolves "postgres" → postgres-0.postgres.swiftpay.svc.cluster.local
  6. Network Policy: Allows egress (CronJob → postgres)
  7. Network Policy: Allows ingress (postgres ← CronJob)
  8. TCP Connection: Established successfully
  9. SQL: UPDATE transactions SET status='FAILED' WHERE...
  10. SQL: SELECT COUNT(*) as reversed_count FROM...
  11. Container exits with code 0 (success)
  12. Job marked as Complete
  13. Kubernetes keeps last 3 successful jobs (successfulJobsHistoryLimit: 3)
```

---

### **Commands Reference: Complete Diagnostic Toolkit**

#### **1. Check CronJob Health**
```bash
# View CronJob status
kubectl get cronjob transaction-timeout-handler -n swiftpay

# Check recent jobs
kubectl get jobs -n swiftpay -l cronjob=transaction-timeout-handler --sort-by=.metadata.creationTimestamp

# Check CronJob events
kubectl describe cronjob transaction-timeout-handler -n swiftpay | grep -A 10 "Events:"
```

#### **2. Debug Job Failures**
```bash
# Find job pods
kubectl get pods -n swiftpay | grep transaction-timeout

# Check pod logs (if pod exists)
kubectl logs <pod-name> -n swiftpay

# Check previous logs (if pod crashed)
kubectl logs <pod-name> -n swiftpay --previous

# Check pod events
kubectl describe pod <pod-name> -n swiftpay | grep -A 20 "Events:"
```

#### **3. Test DNS Resolution**
```bash
# From postgres pod (should always work)
kubectl exec postgres-0 -n swiftpay -- nslookup postgres

# Check CoreDNS health
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

#### **4. Check Network Policies**
```bash
# List all network policies
kubectl get networkpolicies -n swiftpay

# Check specific policy details
kubectl describe networkpolicy cronjob-allow-dns-and-db -n swiftpay
kubectl describe networkpolicy databases-allow-ingress-from-services -n swiftpay

# Verify pod labels match policy selectors
kubectl get pods -n swiftpay --show-labels | grep transaction-timeout
```

#### **5. Check Resource Quotas**
```bash
# View quota status
kubectl describe resourcequota swiftpay-resource-quota -n swiftpay

# Check current usage
kubectl get resourcequota swiftpay-resource-quota -n swiftpay -o yaml | grep -A 10 "status"
```

#### **6. Test Database Connectivity**
```bash
# Direct postgres connection (baseline)
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "SELECT NOW();"

# Check active connections
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT count(*) as connections FROM pg_stat_activity;"

# Check for stuck queries
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT pid, state, query_start, query FROM pg_stat_activity WHERE state != 'idle';"
```

---

### **Lessons Learned**

#### **1. Network Policies are Bidirectional**
- **Egress** policy on source pod is NOT enough
- **Ingress** policy on destination pod is also required
- Both directions must explicitly allow traffic
- Default-deny-all makes this critical

#### **2. CoreDNS Health is Critical for Jobs**
- Long-running pods cache DNS (can survive CoreDNS issues)
- Short-lived Job pods rely on DNS every time
- CoreDNS issues appear as "could not translate host name"
- Check CoreDNS logs first when seeing DNS errors

#### **3. Resource Quotas Need Planning**
- CronJobs create many pods over time
- History limits help but don't prevent quota issues
- Plan quota based on: services + jobs + cronjobs + buffer
- Monitor quota usage: `kubectl top pods -n swiftpay`

#### **4. PostgreSQL Comment Syntax**
- `#` = Shell/YAML comments (outside heredoc)
- `--` = SQL comments (inside heredoc/PostgreSQL)
- Mixed syntax causes confusing errors
- Always use `--` for SQL, even in YAML

#### **5. Diagnostic Methodology**
```
Start Broad → Narrow Down:
  1. Check Kubernetes resources (CronJob, Jobs, Pods)
  2. Check pod events and logs
  3. Check infrastructure (DNS, network)
  4. Check application layer (database, queries)
  5. Test end-to-end with simple cases
```

#### **6. Always Verify Fixes**
- Don't assume fix worked - test it
- Create synthetic test cases
- Check logs show expected output
- Verify database state matches expectations

---

### **Future Improvements**

#### **1. Monitoring & Alerting**
```bash
# Alert if CronJob fails 3 times in a row
# Alert if pending transactions > 0 for > 5 minutes
# Dashboard showing reversal rate per minute
```

#### **2. Metrics Collection**
```yaml
# Add Prometheus metrics:
# - cronjob_success_total
# - cronjob_failure_total
# - transactions_reversed_total
# - transactions_reversed_amount_total
```

#### **3. Backup Reversal Method**
```javascript
// In transaction-service: fallback timer
if (process.env.ENABLE_TIMEOUT_FALLBACK === 'true') {
  setInterval(() => {
    db.query(`UPDATE transactions ...`);
  }, 60000);
}
```

---

## Production-Grade Approach: If This Were Live

> **Context**: Everything documented above was troubleshooting in a development environment. In production, the stakes are higher - stuck transactions = angry users, revenue loss, and potential compliance issues. This section outlines how we'd handle this in a live production system.

---

### **1. Prevention: Design for Failure from Day 1**

#### **Pre-Deployment Validation**

**Integration Test Suite** (What we should have caught):
```yaml
tests/integration/cronjob_e2e_test.go:
  - test_cronjob_dns_resolution:
      # Creates ephemeral namespace with network policies
      # Deploys CronJob
      # Verifies DNS resolves from Job pod to postgres
  
  - test_cronjob_postgres_connection:
      # Verifies Job pod can TCP connect to postgres:5432
      # With default-deny-all network policy enabled
  
  - test_transaction_reversal_end_to_end:
      # 1. Creates pending transaction with old timestamp
      # 2. Waits 90 seconds for CronJob execution
      # 3. Verifies transaction status = FAILED
      # 4. Verifies error_message contains "automatically reversed"
  
  - test_network_policy_allows_cronjob:
      # Validates network policy YAML before deployment
      # Checks both egress (CronJob → postgres) 
      # AND ingress (postgres ← CronJob)
```

**Infrastructure Validation** (Pre-commit hooks):
```bash
# .github/workflows/validate.yml
- name: Validate Kubernetes Manifests
  run: |
    # Check all CronJob containers have resource limits
    yq eval '.spec.jobTemplate.spec.template.spec.containers[].resources' k8s/jobs/*.yaml | grep -q "limits"
    
    # Check CronJob pod labels match network policy selectors
    CRONJOB_LABEL=$(yq eval '.spec.jobTemplate.spec.template.metadata.labels' k8s/jobs/transaction-timeout-handler.yaml)
    NETPOL_SELECTOR=$(yq eval '.spec.podSelector.matchLabels' k8s/policies/network-policies.yaml | grep cronjob)
    
    # Verify services referenced in Jobs exist
    kubectl apply --dry-run=server -f k8s/jobs/
```

**Staging Environment** (Production mirror):
```yaml
Staging Requirements:
  - Identical network policies to production
  - Same resource quotas
  - Same CoreDNS version
  - Load test with 1000 pending transactions
  - Run for 48 hours before prod deployment
  - Chaos engineering: Kill CoreDNS, check CronJob recovery
```

---

### **2. Monitoring & Alerting: Detect Before Users Notice**

#### **Critical Alerts (PagerDuty/OpsGenie)**

```yaml
alerts:
  # Alert 1: Users Directly Impacted
  - name: PendingTransactionsStuck
    query: "count(transactions{status='PENDING', age_minutes > 2}) > 0"
    severity: P0
    action: Page on-call engineer + team lead
    why: User funds are stuck RIGHT NOW
    
  # Alert 2: CronJob Broken
  - name: CronJobFailedMultipleTimes
    query: "rate(cronjob_failures{job='transaction-timeout-handler'}[5m]) > 2"
    severity: P1
    action: Page on-call engineer
    why: Automation is broken, manual intervention needed soon
    
  # Alert 3: CronJob Not Running
  - name: CronJobNotExecuting
    query: "time() - cronjob_last_success_timestamp{job='transaction-timeout-handler'} > 180"
    severity: P1
    action: Page on-call engineer
    why: No executions in 3 minutes = something is very wrong
    
  # Alert 4: Infrastructure Issue
  - name: CoreDNSUnhealthy
    query: "rate(coredns_errors_total[1m]) > 10"
    severity: P2
    action: Slack notification + create Jira ticket
    why: DNS issues will cascade to multiple services
    
  # Alert 5: Resource Pressure
  - name: PodQuotaNearLimit
    query: "(pods_used / pods_limit) > 0.85"
    severity: P3
    action: Slack notification
    why: Will hit quota soon, need to increase or cleanup
```

#### **Observability Dashboard** (Grafana)

```
Transaction Timeout Dashboard:
┌────────────────────────────────────────────────────────────┐
│ Pending Transactions (Real-time)                          │
│ ┌────┐                                                     │
│ │ 0  │ Current Pending   │ 247 │ Reversed Today          │
│ └────┘                   └─────┘                          │
├────────────────────────────────────────────────────────────┤
│ CronJob Health (Last Hour)                                │
│ Success Rate: 100% (60/60)    Avg Duration: 9.2s         │
│ Last Run: 15 seconds ago      Next Run: 45 seconds       │
├────────────────────────────────────────────────────────────┤
│ Reversal Rate (Last 24h)                                  │
│ ▂▃▅▇▅▃▂▁▂▃▅▆▅▃▂▁▂▃▅▇▅▃▂▁ (Hourly trend)                  │
├────────────────────────────────────────────────────────────┤
│ Network Policy Denials (If using Cilium/Calico)          │
│ CronJob → Postgres: 0 blocked connections                │
│ CronJob → CoreDNS:  0 blocked connections                │
└────────────────────────────────────────────────────────────┘
```

---

### **3. Graceful Degradation: Multiple Layers of Defense**

#### **Defense in Depth Strategy**

```
Layer 1: Kubernetes CronJob (Primary)
  ↓ (Fails: DNS issues, network policies, quota)
  
Layer 2: In-App Timer in transaction-service (Backup)
  ↓ (Fails: Service crashed, pod restarted)
  
Layer 3: Database-Level pg_cron (Ultimate Backup)
  ↓ (Fails: Database down = we have bigger problems)
  
Layer 4: Manual Runbook (Human Intervention)
```

**Implementation:**

**Layer 1 - CronJob** (Already implemented):
```yaml
# k8s/jobs/transaction-timeout-handler.yaml
schedule: "* * * * *"
```

**Layer 2 - In-App Fallback**:
```javascript
// services/transaction-service/src/fallback-timeout.js

let fallbackEnabled = false;
let fallbackTimer = null;

// Check if CronJob is healthy
async function checkCronJobHealth() {
  try {
    const lastReversal = await db.query(`
      SELECT MAX(completed_at) as last_reversal 
      FROM transactions 
      WHERE status = 'FAILED' 
      AND error_message LIKE '%automatically reversed%'
    `);
    
    const lastReversalAge = Date.now() - lastReversal.rows[0]?.last_reversal;
    
    // If no reversals in 5 minutes AND pending transactions exist
    if (lastReversalAge > 300000) {
      const pendingCount = await db.query(`
        SELECT COUNT(*) FROM transactions WHERE status = 'PENDING'
      `);
      
      if (pendingCount.rows[0].count > 0) {
        console.warn('CronJob appears unhealthy, activating fallback');
        activateFallback();
      }
    }
  } catch (err) {
    console.error('Health check failed:', err);
  }
}

function activateFallback() {
  if (fallbackEnabled) return;
  
  fallbackEnabled = true;
  console.warn('FALLBACK ACTIVATED: In-app timeout handling enabled');
  
  fallbackTimer = setInterval(async () => {
    try {
      const result = await db.query(`
        UPDATE transactions 
        SET status = 'FAILED',
            error_message = 'Transaction timeout - reversed by fallback mechanism',
            completed_at = CURRENT_TIMESTAMP
        WHERE status = 'PENDING' 
        AND created_at < NOW() - INTERVAL '1 minute'
      `);
      
      if (result.rowCount > 0) {
        console.warn(`Fallback reversed ${result.rowCount} transactions`);
        // Emit metric for alerting
        metrics.increment('fallback.reversals', result.rowCount);
      }
    } catch (err) {
      console.error('Fallback reversal failed:', err);
    }
  }, 60000); // Every minute
}

// Check every 2 minutes
setInterval(checkCronJobHealth, 120000);

// Feature flag for manual activation
if (process.env.ENABLE_TIMEOUT_FALLBACK === 'true') {
  console.warn('Fallback manually enabled via environment variable');
  activateFallback();
}
```

**Layer 3 - Database Level**:
```sql
-- Install pg_cron extension (one-time)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule timeout job (fallback to fallback)
SELECT cron.schedule(
  'reverse-pending-transactions-ultimate-fallback',
  '* * * * *',
  $$
    UPDATE transactions 
    SET status = 'FAILED',
        error_message = 'Transaction timeout - reversed by database-level fallback',
        completed_at = CURRENT_TIMESTAMP,
        processing_started_at = COALESCE(processing_started_at, created_at)
    WHERE status = 'PENDING' 
    AND created_at < NOW() - INTERVAL '2 minutes'
  $$
);

-- Note: Uses 2 minute threshold to avoid conflict with CronJob (1 minute)
```

---

### **4. Zero-Downtime Incident Response**

#### **If This Happened in Production: Runbook**

**Phase 1: Immediate Response (0-5 minutes)**

```bash
# ===== STEP 1: Assess Blast Radius =====
# How many users affected? How much money stuck?
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "
  SELECT 
    COUNT(*) as stuck_transactions,
    COUNT(DISTINCT from_user_id) as affected_users,
    SUM(amount) as total_stuck_amount,
    MAX(NOW() - created_at) as oldest_pending_age
  FROM transactions 
  WHERE status = 'PENDING';
"

# Output Example:
# stuck_transactions | affected_users | total_stuck_amount | oldest_pending_age
# 47                | 23            | 15,234.50         | 00:12:34

# ===== STEP 2: Activate Fallback Immediately =====
# Don't wait to fix root cause - stop the bleeding first
kubectl set env deployment/transaction-service -n swiftpay \
  ENABLE_TIMEOUT_FALLBACK=true

# Verify fallback activated (check logs)
kubectl logs -n swiftpay -l app=transaction-service --tail=20 | grep "FALLBACK ACTIVATED"

# ===== STEP 3: Manual Emergency Reversal =====
# While fallback is activating, manually reverse to give immediate relief
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "
  UPDATE transactions 
  SET status = 'FAILED',
      error_message = 'Transaction timeout - manually reversed during incident',
      completed_at = CURRENT_TIMESTAMP,
      processing_started_at = COALESCE(processing_started_at, created_at)
  WHERE status = 'PENDING' 
  AND created_at < NOW() - INTERVAL '1 minute';
"

# ===== STEP 4: Notify Stakeholders =====
# Post in #incidents Slack channel
# Update status page if customer-facing
# Start incident timeline document
```

**Phase 2: Root Cause Analysis (5-30 minutes)**

```bash
# ===== STEP 1: Check CronJob Status =====
kubectl get cronjob transaction-timeout-handler -n swiftpay
kubectl get jobs -n swiftpay | grep transaction-timeout
kubectl describe cronjob transaction-timeout-handler -n swiftpay | grep -A 10 "Events:"

# ===== STEP 2: Check Recent Job Pod Logs =====
POD=$(kubectl get pods -n swiftpay | grep transaction-timeout | tail -1 | awk '{print $1}')
kubectl logs $POD -n swiftpay
kubectl describe pod $POD -n swiftpay | grep -A 20 "Events:"

# ===== STEP 3: Check CoreDNS Health =====
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100 | grep -i error

# ===== STEP 4: Check Network Policies =====
kubectl get networkpolicies -n swiftpay
kubectl describe networkpolicy cronjob-allow-dns-and-db -n swiftpay
kubectl describe networkpolicy databases-allow-ingress-from-services -n swiftpay

# ===== STEP 5: Check Resource Quotas =====
kubectl describe resourcequota swiftpay-resource-quota -n swiftpay | grep -A 5 "Used"

# ===== STEP 6: Review Recent Changes =====
# Check deployment history
kubectl rollout history deployment -n swiftpay
# Check recent git commits
git log --oneline --since="1 day ago"
# Check recent kubectl apply commands (audit logs)
```

**Phase 3: Deploy Fix (30-60 minutes)**

```bash
# ===== IMPORTANT: Test in Staging First =====
# 1. Apply fix to staging
# 2. Create test pending transaction
# 3. Verify CronJob reverses it
# 4. Wait 30 minutes, check for side effects

# ===== Production Deployment =====
# Get peer review on fix
git diff main...fix/cronjob-network-policy

# Create change request ticket
# Document: What broke, why, how fix works, rollback plan

# Apply fix with monitoring
kubectl apply -f k8s/policies/network-policies.yaml

# Watch CronJob for next 3 executions
watch kubectl get jobs -n swiftpay | grep transaction-timeout

# Check logs for success
kubectl logs -n swiftpay -l cronjob=transaction-timeout-handler --tail=50

# ===== Verify Fix =====
# Create test transaction
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "
  INSERT INTO transactions (id, from_user_id, to_user_id, amount, status, created_at) 
  VALUES ('PROD-TEST-' || floor(random() * 10000)::text, 'test', 'test', 1.00, 
          'PENDING', NOW() - INTERVAL '5 minutes');
"

# Wait 90 seconds, verify reversed
sleep 90
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "
  SELECT id, status, error_message FROM transactions WHERE id LIKE 'PROD-TEST%';
"

# Cleanup test
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "
  DELETE FROM transactions WHERE id LIKE 'PROD-TEST%';
"

# ===== Disable Fallback (After 24h of stability) =====
kubectl set env deployment/transaction-service -n swiftpay \
  ENABLE_TIMEOUT_FALLBACK-
```

**Phase 4: Post-Incident (After incident resolved)**

```markdown
# Post-Mortem Template

## Incident Summary
**Date**: 2026-01-14
**Duration**: 2 hours 34 minutes
**Severity**: P1 - Service Degradation
**Impact**: 47 transactions stuck, 23 users affected, $15,234.50 locked

## Timeline (All times UTC)
- 00:15 - Incident detected via PagerDuty alert
- 00:18 - On-call engineer confirmed issue
- 00:20 - Fallback activated
- 00:22 - Manual reversal completed (immediate relief)
- 00:45 - Root cause identified (network policy)
- 01:30 - Fix tested in staging
- 02:15 - Fix deployed to production
- 02:30 - Verified working, incident closed
- 02:49 - Post-mortem meeting scheduled

## Root Cause
Network policy `databases-allow-ingress-from-services` did not include 
CronJob pods in its ingress rules. CronJob could send (egress) but 
postgres couldn't receive (ingress).

## What Went Well
- Monitoring detected issue immediately (< 3 minutes)
- Fallback mechanism prevented extended downtime
- Clear runbook allowed fast response
- No data loss or corruption

## What Went Wrong
- Integration tests didn't catch network policy gap
- Staging environment had different network policies than prod
- No pre-deployment validation of CronJob connectivity

## Action Items
| Item | Owner | Due Date | Priority |
|------|-------|----------|----------|
| Add integration test for CronJob network access | @eng-team | 2026-01-21 | P0 |
| Sync staging network policies with prod | @devops | 2026-01-16 | P0 |
| Add pre-deployment CronJob smoke test | @devops | 2026-01-21 | P1 |
| Document network policy review checklist | @security | 2026-01-28 | P2 |
| Implement Layer 3 fallback (pg_cron) | @eng-team | 2026-02-15 | P2 |
```

---

### **5. Architecture Improvements for Production**

#### **Option A: Dedicated Timeout Service (Recommended)**

Instead of CronJob, use a long-running Deployment:

```yaml
# k8s/deployments/transaction-timeout-service.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: transaction-timeout-service
  namespace: swiftpay
spec:
  replicas: 1  # Single replica with leader election
  selector:
    matchLabels:
      app: transaction-timeout-service
  template:
    metadata:
      labels:
        app: transaction-timeout-service
    spec:
      containers:
      - name: timeout-handler
        image: swiftpay/transaction-timeout-service:1.0.0
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
        env:
        - name: DB_HOST
          value: postgres.swiftpay.svc.cluster.local
        - name: CHECK_INTERVAL_MS
          value: "60000"  # Every minute
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
```

**Service Code**:
```javascript
// services/transaction-timeout-service/src/index.js
const express = require('express');
const { Pool } = require('pg');

const app = express();
const db = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
});

let lastSuccessfulRun = Date.now();
let consecutiveFailures = 0;

async function reverseTimeouts() {
  try {
    const result = await db.query(`
      UPDATE transactions 
      SET status = 'FAILED',
          error_message = 'Transaction timeout - automatically reversed by system',
          completed_at = CURRENT_TIMESTAMP,
          processing_started_at = COALESCE(processing_started_at, created_at)
      WHERE status = 'PENDING' 
      AND created_at < NOW() - INTERVAL '1 minute'
      RETURNING id, amount;
    `);
    
    lastSuccessfulRun = Date.now();
    consecutiveFailures = 0;
    
    if (result.rowCount > 0) {
      console.log(`Reversed ${result.rowCount} transactions`);
      // Emit metrics
      metrics.increment('transactions.reversed', result.rowCount);
      metrics.gauge('transactions.reversed.amount', 
        result.rows.reduce((sum, r) => sum + parseFloat(r.amount), 0)
      );
    }
  } catch (err) {
    consecutiveFailures++;
    console.error('Failed to reverse timeouts:', err);
    metrics.increment('transactions.reversal.errors');
  }
}

// Run every minute
setInterval(reverseTimeouts, parseInt(process.env.CHECK_INTERVAL_MS) || 60000);

// Health check endpoints
app.get('/healthz', (req, res) => {
  const timeSinceLastSuccess = Date.now() - lastSuccessfulRun;
  if (timeSinceLastSuccess > 300000) { // 5 minutes
    return res.status(500).json({ status: 'unhealthy', timeSinceLastSuccess });
  }
  res.json({ status: 'healthy', lastSuccessfulRun });
});

app.get('/ready', async (req, res) => {
  try {
    await db.query('SELECT 1');
    res.json({ status: 'ready' });
  } catch (err) {
    res.status(500).json({ status: 'not ready', error: err.message });
  }
});

app.listen(8080, () => console.log('Timeout service running on :8080'));
```

**Pros vs CronJob:**
- ✅ No Job pod churn (resource efficient)
- ✅ No DNS resolution issues (persistent connection)
- ✅ Better observability (logs, metrics, health checks)
- ✅ Easier to test locally
- ✅ Graceful shutdown handling
- ✅ Can expose Prometheus metrics endpoint

**Cons:**
- ❌ More complex (needs proper shutdown, signal handling)
- ❌ Requires leader election for multi-replica (or use single replica)

---

#### **Option B: Event-Driven Architecture (Advanced)**

Use RabbitMQ delayed messages for self-reversing transactions:

```javascript
// When creating transaction
await rabbitmq.publish('transactions', 'transaction.created', {
  transactionId: 'TXN-123',
  // ... transaction data
}, {
  headers: {
    'x-delay': 60000  // 1 minute delay
  }
});

// Worker listens for delayed messages
rabbitmq.consume('transaction-timeout-check', async (msg) => {
  const { transactionId } = msg.content;
  
  // Check if still pending
  const tx = await db.query(
    'SELECT status FROM transactions WHERE id = $1',
    [transactionId]
  );
  
  if (tx.rows[0]?.status === 'PENDING') {
    await db.query(
      'UPDATE transactions SET status = $1, error_message = $2 WHERE id = $3',
      ['FAILED', 'Transaction timeout', transactionId]
    );
  }
});
```

**Pros:**
- ✅ Scales to millions of transactions
- ✅ Each transaction self-manages (no polling)
- ✅ Distributed (works across regions)

**Cons:**
- ❌ More complex architecture
- ❌ Depends on RabbitMQ reliability
- ❌ Harder to debug

---

### **6. Cost Analysis**

#### **Current CronJob Approach**
```
Resources per execution:
- CPU: 50m request, 100m limit
- Memory: 64Mi request, 128Mi limit
- Duration: ~10 seconds

Monthly cost (AWS EKS pricing):
- 1440 executions/day × 30 days = 43,200 executions
- 43,200 × 10 seconds = 120 hours of pod time
- Cost: ~$5-10/month

Additional costs:
- Network policies: $0 (included)
- Monitoring/logging: ~$2/month
- Total: ~$7-12/month
```

#### **Dedicated Service Approach**
```
Resources (24/7 running):
- CPU: 50m request
- Memory: 64Mi request

Monthly cost:
- 720 hours × $0.03/vCPU-hour × 0.05 vCPU = ~$1.08
- 720 hours × $0.004/GB-hour × 0.064 GB = ~$0.18
- Total: ~$1.26/month

Savings: $5.74/month BUT:
- Better reliability
- Easier debugging
- No Job pod churn
- ROI: Prevents one incident = pays for itself 100x over
```

---

### **7. Final Production Recommendations**

#### **For SwiftPay (Phased Approach)**

**Phase 1: Ship Current Solution (Week 1)**
- ✅ Keep CronJob with all fixes
- ✅ Add fallback timer in transaction-service (behind feature flag)
- ✅ Set up alerts (pending transactions, CronJob failures)
- ✅ Document runbook for on-call
- ✅ Add integration tests

**Phase 2: Improve Observability (Week 2-3)**
- ✅ Add Prometheus metrics to CronJob output
- ✅ Build Grafana dashboard
- ✅ Set up distributed tracing
- ✅ Add structured logging

**Phase 3: Architecture Migration (Month 2)**
- ✅ Build dedicated timeout service
- ✅ Deploy to staging, run A/B test
- ✅ Gradual rollout: 10% → 50% → 100%
- ✅ Migrate fully, deprecate CronJob

**Phase 4: Scale for Growth (Quarter 2)**
- ✅ Event-driven architecture (if handling >10k tx/day)
- ✅ Multi-region deployment
- ✅ Advanced failure scenarios (chaos engineering)

---

### **8. Key Takeaways for Production**

1. **Assume Everything Will Fail**
   - Build fallbacks for your fallbacks
   - Network policies will be misconfigured
   - DNS will break
   - CoreDNS will lose API connection
   - Design for these realities

2. **Monitor Everything**
   - Alert before users notice
   - Multiple layers of alerts (business metrics + infrastructure)
   - Dashboards should tell a story
   - Logs should be searchable and actionable

3. **Test in Production-Like Environments**
   - Staging must mirror production exactly
   - Same network policies, quotas, DNS config
   - Chaos engineering: Break things on purpose
   - Load test with 10x expected traffic

4. **Documentation is Code**
   - Runbooks for 3 AM incidents
   - Post-mortems after every issue
   - Architecture decision records (ADRs)
   - Update docs as you fix issues

5. **Gradual Rollouts**
   - Deploy to 1% of traffic first
   - Canary deployments for risky changes
   - Always have a rollback plan
   - Rollback should be one command

6. **Cost-Conscious Engineering**
   - $10/month CronJob vs $100k incident
   - Reliability has ROI
   - But don't over-engineer
   - Start simple, scale when needed

7. **Blameless Culture**
   - Systems fail, not people
   - Focus on prevention, not blame
   - Every incident is a learning opportunity
   - Share learnings across team

---

**Production-Ready Checklist:**
```
Before deploying transaction timeout handler to production:

Infrastructure:
[ ] Integration tests cover network policy scenarios
[ ] Staging environment mirrors production exactly
[ ] Resource quotas have 20% buffer
[ ] Network policies validated with dry-run
[ ] CoreDNS health monitoring in place

Observability:
[ ] Prometheus metrics exported
[ ] Grafana dashboard created
[ ] PagerDuty alerts configured
[ ] Slack notifications set up
[ ] Distributed tracing enabled

Resilience:
[ ] Fallback timer implemented
[ ] Database-level pg_cron backup (optional)
[ ] Circuit breaker for cascading failures
[ ] Graceful degradation tested
[ ] Chaos engineering scenarios passed

Documentation:
[ ] Runbook written and reviewed
[ ] Architecture diagram updated
[ ] Post-incident template prepared
[ ] Team trained on incident response
[ ] On-call rotation schedule created

Deployment:
[ ] Peer review completed
[ ] Change request approved
[ ] Rollback plan documented
[ ] Smoke tests defined
[ ] Communication plan for stakeholders
```

---

**Document Version**: 3.0  
**Last Updated**: January 14, 2026  
**Next Review**: After production deployment

