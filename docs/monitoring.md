# Monitoring: Understanding System Health at Scale

> **The Big Picture**: Monitoring isn't just about graphs and alerts. It's about understanding how your system behaves, why it breaks, and how to prevent problems before users notice.

---

## Table of Contents

1. [Why Monitoring Exists](#why-monitoring-exists)
2. [The Mental Model: What Are We Actually Watching?](#the-mental-model)
3. [How Monitoring Fits Into the System](#how-monitoring-fits-into-the-system)
4. [What We're Monitoring and Why](#what-were-monitoring-and-why)
5. [Architecture: How Prometheus Works](#architecture-how-prometheus-works)
6. [Tradeoffs: Why Prometheus Over Alternatives](#tradeoffs-why-prometheus-over-alternatives)
7. [What Breaks at 10x Traffic](#what-breaks-at-10x-traffic)
8. [Deployment Guide](#deployment-guide)
9. [Understanding the Code](#understanding-the-code)

---

## Why Monitoring Exists

## Local Workspace Coexistence Note

When `SwiftPay` runs inside the shared `DevOps-Easy-Learning` workspace, do not start the local Docker Compose monitoring or logging profiles alongside the central [PORT-ALLOCATION-MATRIX.md](/Users/raymond/Documents/DevOps-Easy-Learning/PORT-ALLOCATION-MATRIX.md) stack owner in `Obervability-Stack`.

Reason:

- `SwiftPay` local monitoring publishes host ports that overlap with the shared observability stack:
- `9090` Prometheus
- `9093` Alertmanager
- `3100` Loki

Safe rule:

- use `Obervability-Stack` as the shared monitoring/logging owner for the workspace
- use `SwiftPay` local monitoring only when running SwiftPay in isolation

### The Problem We're Solving

**Without monitoring, you're flying blind:**

```
User reports: "The app is slow"
You: "Which part? When? How slow?"
User: "I don't know, just slow"
You: *checks logs, guesses, restarts services randomly*
```

**With monitoring, you have answers:**

```
Alert: "API Gateway 95th percentile response time > 1 second"
You: "Ah, API Gateway is slow. Let me check why."
*Looks at metrics*
"Database queries are taking 500ms. Let me check database."
"PostgreSQL connection pool exhausted. Need to increase pool size."
```

### The Three Questions Monitoring Answers

1. **What's broken?** (Service health, errors)
2. **Why is it broken?** (Root cause analysis)
3. **How do we prevent it?** (Trends, capacity planning)

### Real-World Example: The Silent Failure

**Scenario**: Transaction service is failing, but users don't notice immediately.

**Without monitoring:**
- Users start complaining after 30 minutes
- You discover the issue when support tickets spike
- You scramble to find the problem
- Revenue lost, reputation damaged

**With monitoring:**
- Alert fires in 2 minutes: "Transaction failure rate > 5%"
- You see: "Wallet service timeout errors"
- You check: "Wallet service CPU at 95%"
- You fix: "Scale wallet service from 2 to 5 pods"
- Problem solved before most users notice

---

## The Mental Model: What Are We Actually Watching?

### Think of Your System Like a Car Dashboard

**Car Dashboard Shows:**
- Speed (how fast you're going)
- RPM (engine performance)
- Fuel (resource availability)
- Temperature (system health)
- Warning lights (problems)

**Monitoring Dashboard Shows:**
- Request rate (how many requests/second)
- Response time (how fast responses are)
- Error rate (how many failures)
- Resource usage (CPU, memory, disk)
- Alerts (problems detected)

### The Four Golden Signals

These are the four metrics that tell you everything:

**1. Latency (How Fast?)**
```
Question: How long does a request take?
Metric: http_request_duration_seconds
Why: Slow = bad user experience
```

**2. Traffic (How Much?)**
```
Question: How many requests are we handling?
Metric: http_requests_total
Why: Need to know load to plan capacity
```

**3. Errors (How Many Failures?)**
```
Question: What percentage of requests fail?
Metric: http_requests_total{code=~"5.."}
Why: Failures = lost revenue, unhappy users
```

**4. Saturation (How Full?)**
```
Question: How close are we to capacity limits?
Metric: CPU usage, memory usage, queue depth
Why: Near capacity = about to break
```

### The Mental Model in Practice

**When you see this:**
```
Latency: 2 seconds (normal: 200ms)
Traffic: 1000 req/s (normal: 100 req/s)
Errors: 5% (normal: 0.1%)
Saturation: CPU 95% (normal: 30%)
```

**You think:**
- "Traffic is 10x normal" → "Something is causing a spike"
- "CPU is 95%" → "We're at capacity"
- "Latency is high" → "System is overloaded"
- "Errors are high" → "System is failing under load"

**Action:**
- Scale up services (add more pods)
- Find what's causing traffic spike
- Check if it's an attack or legitimate traffic

---

## How Monitoring Fits Into the System

### The Complete Picture

```
┌─────────────────────────────────────────────────────────┐
│                    YOUR APPLICATION                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ Services  │  │ Database │  │  Queue   │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │              │              │                    │
│       └──────────────┴──────────────┘                    │
│                    │                                     │
│        ┌───────────┴───────────┐                        │
│        │                       │                        │
│        │ Exposes /metrics      │ Writes logs            │
│        ▼                       ▼                        │
└─────────────────────────────────────────────────────────┘
        │                       │
        │ Scrapes every 15s      │ Logs pushed via Promtail
        ▼                       ▼
┌──────────────────┐    ┌──────────────────┐
│   PROMETHEUS     │    │      LOKI        │
│  (Metrics)       │    │  (Logs)          │
│  - CPU, Memory   │    │  - Error logs    │
│  - Request rate  │    │  - Stack traces  │
│  - Response time   │    │  - Debug info   │
└────────┬─────────┘    └────────┬─────────┘
         │                       │
         │ Queries               │ Queries
         ▼                       ▼
┌─────────────────────────────────────────┐
│              GRAFANA                    │
│  ┌──────────────────────────────────┐   │
│  │  Dashboards:                      │   │
│  │  - Metrics from Prometheus       │   │
│  │  - Logs from Loki                 │   │
│  │  - Correlate metrics + logs       │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
         │
         │ Alerts
         ▼
┌──────────────────┐
│  ALERTMANAGER    │
│  (Notifications) │
└──────────────────┘
```

### The Two Pillars: Metrics and Logs

**Prometheus (Metrics) = Numbers**
- "What": CPU is 95%, 1000 requests/second, 5% error rate
- Time-series data (numbers over time)
- Optimized for aggregation (sum, average, rate)

**Loki (Logs) = Text**
- "Why": "Connection timeout: wallet-service:3001", stack traces, debug messages
- Text data with timestamps
- Optimized for searching and filtering

**Why You Need Both:**
- **Metrics tell you WHAT is wrong**: "Error rate is 10%"
- **Logs tell you WHY it's wrong**: "Error: Connection timeout to wallet-service"
- **Together**: You know what's broken AND why

### The Flow: How Metrics Travel

**Step 1: Services Expose Metrics**
```javascript
// In your service code (e.g., api-gateway/server.js)
const httpRequestsTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

// Increment when request happens
app.get('/api/users', (req, res) => {
  httpRequestsTotal.inc({ method: 'GET', route: '/api/users', status_code: 200 });
  // ... handle request
});
```

**Step 2: Prometheus Scrapes Metrics**
```yaml
# Prometheus config (prometheus-config.yaml)
scrape_configs:
  - job_name: 'api-gateway'
    kubernetes_sd_configs:  # Auto-discover pods
      - role: pod
        namespaces:
          names: ['swiftpay']
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: api-gateway
        action: keep
```

**What happens:**
1. Prometheus discovers all pods with `app=api-gateway` label
2. Every 15 seconds, Prometheus calls `http://pod-ip:3000/metrics`
3. Service returns metrics in Prometheus format
4. Prometheus stores metrics in its time-series database

**Step 3: You Query Metrics**
```promql
# In Prometheus UI or Grafana
rate(http_requests_total[5m])  # Requests per second over 5 minutes
```

**Step 4: Alerts Fire When Thresholds Exceeded**
```yaml
# Alert rule (prometheus-rules.yaml)
- alert: HighErrorRate
  expr: rate(http_requests_total{code=~"5.."}[5m]) > 0.1
  for: 2m
  # If error rate > 10% for 2 minutes, fire alert
```

---

## Why Loki: The Missing Piece

### The Problem: Logs Are Scattered

**Without Loki:**
```
Service 1 logs: kubectl logs pod-1
Service 2 logs: kubectl logs pod-2
Service 3 logs: kubectl logs pod-3
...
Service 10 logs: kubectl logs pod-10

Problem: How do you find the error that spans multiple services?
Problem: How do you correlate errors with metrics?
Problem: Logs are lost when pods restart?
```

**With Loki:**
```
All logs → Loki → Query with LogQL
"Show me all errors from wallet-service in last hour"
"Show me all logs containing 'timeout' from transaction-service"
"Correlate errors with Prometheus metrics"
```

### What Happens Without Loki

**Scenario: User reports "Transaction failed"**

**Without Loki:**
1. Check transaction service logs: "Error: wallet-service timeout"
2. Check wallet service logs: "Error: database connection pool exhausted"
3. Check database logs: "Too many connections"
4. Manually correlate timestamps
5. Takes 30+ minutes to find root cause

**With Loki:**
1. Query: `{app="transaction-service"} |= "timeout"`
2. See: "Error: wallet-service timeout at 10:05:23"
3. Query: `{app="wallet-service"} |="connection"` around 10:05:23
4. See: "Error: database connection pool exhausted at 10:05:22"
5. Root cause found in 2 minutes

### Why Loki Over Alternatives

**Loki vs ELK Stack (Elasticsearch, Logstash, Kibana)**

**Loki:**
- ✅ **Lightweight**: Much smaller resource footprint
- ✅ **Simple**: Easier to set up and maintain
- ✅ **Prometheus-native**: Same query language style (LogQL vs PromQL)
- ✅ **Cost-effective**: Lower storage costs
- ❌ **Less powerful**: Not as feature-rich as Elasticsearch

**ELK Stack:**
- ✅ **Powerful**: Full-text search, complex queries
- ✅ **Mature**: Battle-tested, lots of features
- ❌ **Heavy**: Requires significant resources
- ❌ **Complex**: Harder to set up and maintain
- ❌ **Expensive**: High storage and compute costs

**Why we chose Loki:**
- Learning project (simpler is better)
- Integrates with Prometheus/Grafana (same ecosystem)
- Lower resource usage (important for local development)
- Good enough for most use cases

**Loki vs CloudWatch Logs (AWS)**

**Loki:**
- ✅ **Multi-cloud**: Works anywhere
- ✅ **Self-hosted**: Full control
- ✅ **Free**: No per-GB charges
- ❌ **Self-managed**: You maintain it

**CloudWatch Logs:**
- ✅ **Managed**: AWS handles everything
- ✅ **Integrated**: Works with all AWS services
- ❌ **AWS-only**: Locked to AWS
- ❌ **Expensive**: Pay per GB ingested and stored
- ❌ **Less flexible**: Harder to customize

**Why we chose Loki:**
- Multi-cloud flexibility
- Learning (understand how it works)
- Cost-effective (no per-GB charges)

### How Loki Works

**Architecture:**
```
Services → Promtail (log shipper) → Loki → Grafana
```

**Promtail (Log Shipper):**
- Runs as DaemonSet (one per node)
- Reads logs from pods (via Kubernetes API)
- Sends logs to Loki
- Adds labels (pod name, namespace, app)

**Loki:**
- Receives logs from Promtail
- Stores logs in chunks (compressed)
- Indexes logs by labels (not full-text)
- Allows querying with LogQL

**Why this architecture:**
- **Pull model**: Promtail reads logs (like Prometheus scrapes metrics)
- **Label-based indexing**: Fast queries, low storage
- **Compression**: Efficient storage (logs compress well)

### What Breaks at 10x Traffic (Logs)

**Normal:**
- 1000 log lines/second
- 100MB logs/day
- 7-day retention = 700MB

**10x Traffic:**
- 10,000 log lines/second
- 1GB logs/day
- 7-day retention = 7GB

**What breaks:**

**1. Log Ingestion Overload**
```
Normal: Loki handles 1000 lines/second easily
10x:    10,000 lines/second
Result: Loki can't keep up, logs dropped or delayed
```

**Why it breaks:**
- Loki has ingestion limits
- Too many logs = queue backs up
- Logs get dropped or delayed

**How to fix:**
- Scale Loki (add more replicas)
- Increase Loki resources (more CPU/memory)
- Reduce log verbosity (log less)

**2. Storage Exhaustion**
```
Normal: 100MB/day = 700MB for 7 days
10x:    1GB/day = 7GB for 7 days
Result: Storage fills up, old logs deleted early
```

**Why it breaks:**
- More traffic = more logs
- Storage limited (100GB in our config)
- Retention period might need adjustment

**How to fix:**
- Increase storage (200GB, 500GB)
- Reduce retention (3 days instead of 7)
- Archive old logs to object storage (S3)

**3. Query Performance Degradation**
```
Normal: Query returns in 100ms
10x:    Query returns in 5 seconds
Result: Grafana dashboards slow, users frustrated
```

**Why it breaks:**
- More logs = larger dataset to search
- Queries scan more data
- Index can't keep up

**How to fix:**
- Optimize queries (use labels, time ranges)
- Increase Loki resources
- Use log sampling (only index important logs)

### The Value: Metrics + Logs Together

**Example: Debugging a Production Issue**

**Step 1: Metrics Alert**
```
Alert: "High error rate: 10%"
Time: 10:05:00
```

**Step 2: Check Metrics**
```
Prometheus query: rate(http_requests_total{code=~"5.."}[5m])
Result: Error rate spiked at 10:05:00
Service: transaction-service
```

**Step 3: Check Logs**
```
Loki query: {app="transaction-service"} |="error" [10:04:00, 10:06:00]
Result: "Error: wallet-service timeout"
Time: 10:05:23
```

**Step 4: Correlate**
```
Check wallet-service metrics: CPU 100% at 10:05:00
Check wallet-service logs: "Database connection pool exhausted"
```

**Step 5: Root Cause**
```
Wallet service overloaded → Can't handle requests → Transaction service times out
Solution: Scale wallet service
```

**Without Loki:**
- You'd have to manually check each service's logs
- Hard to correlate timestamps
- Takes 30+ minutes

**With Loki:**
- Single query finds the error
- Easy to correlate with metrics
- Root cause in 2 minutes

## What We're Monitoring and Why

### Application Metrics (Business Logic)

**Why**: These tell you if your business is working.

**Examples:**
- `transactions_total` - Are transactions processing?
- `transactions_total{status="failed"}` - How many are failing?
- `wallet_balance_sum` - Total money in system
- `transfer_amount_sum` - Money moved today

**What breaks at 10x traffic:**
- Transaction queue fills up → Transactions delayed
- Database locks → Deadlocks, timeouts
- Wallet service overloaded → Can't check balances

**How monitoring helps:**
- See transaction rate increasing → Scale transaction service
- See failure rate spike → Investigate before it's critical
- See queue depth growing → Add more workers

### Infrastructure Metrics (System Health)

**Why**: These tell you if your infrastructure can handle load.

**Examples:**
- `process_cpu_seconds_total` - CPU usage
- `process_resident_memory_bytes` - Memory usage
- `database_connections_active` - Database connections
- `redis_operations_total` - Cache operations

**What breaks at 10x traffic:**
- CPU hits 100% → Requests queue up, timeouts
- Memory fills up → OOM kills, service restarts
- Database connections exhausted → Can't process requests
- Cache evictions → More database load

**How monitoring helps:**
- See CPU trending up → Scale before hitting 100%
- See memory growing → Add more memory or scale
- See connection pool full → Increase pool size or scale

### Request Metrics (User Experience)

**Why**: These tell you what users experience.

**Examples:**
- `http_request_duration_seconds` - How fast responses are
- `http_requests_total` - Request volume
- `http_requests_total{code=~"5.."}` - Error count

**What breaks at 10x traffic:**
- Response time increases → Users wait longer
- Error rate increases → Users see failures
- Request queue backs up → Timeouts

**How monitoring helps:**
- See latency increasing → Find bottleneck
- See errors spiking → Fix before users complain
- See queue depth → Scale proactively

---

## Architecture: How Prometheus Works

### Pull Model vs Push Model

**Prometheus uses Pull Model:**
```
Prometheus → Scrapes → Services
(Active)              (Passive)
```

**Why Pull?**
- ✅ **Simple**: Services just expose `/metrics`, no client needed
- ✅ **Reliable**: Prometheus controls when to scrape
- ✅ **Discovery**: Can auto-discover services in Kubernetes
- ❌ **Tradeoff**: If Prometheus is down, no metrics collected

**Alternative: Push Model (e.g., StatsD, Datadog)**
```
Services → Push → Metrics Server
(Active)         (Passive)
```

**Why Push?**
- ✅ **Works behind firewalls**: Services push out
- ✅ **Lower latency**: Metrics sent immediately
- ❌ **Tradeoff**: Need client library, more complex

**Why we chose Pull:**
- Kubernetes makes service discovery easy
- Simpler architecture (services just expose endpoint)
- Prometheus handles retries and failures

### Time-Series Database

**What is a time-series database?**
- Stores data points with timestamps
- Optimized for time-based queries
- Efficient compression (similar values stored together)

**Example:**
```
Timestamp           | Value
2025-12-28 10:00:00 | 100 req/s
2025-12-28 10:00:15 | 105 req/s
2025-12-28 10:00:30 | 110 req/s
```

**Why time-series?**
- Need to see trends over time
- Need to query "requests per second over last 5 minutes"
- Need to store historical data for analysis

**Storage:**
- Prometheus stores on disk (local storage)
- Retention: 30 days (configurable)
- For longer retention: Use Thanos or Cortex (external storage)

### Kubernetes Service Discovery

**How Prometheus finds services:**

```yaml
# prometheus-config.yaml
kubernetes_sd_configs:
  - role: pod
    namespaces:
      names: ['swiftpay']
```

**What happens:**
1. Prometheus queries Kubernetes API: "Give me all pods in swiftpay namespace"
2. Kubernetes returns: List of pods with labels
3. Prometheus filters: Only pods with `app=api-gateway` label
4. Prometheus scrapes: `http://pod-ip:3000/metrics`

**Why this is powerful:**
- Auto-discovers new pods (when you scale up)
- Auto-removes dead pods (when pods die)
- No manual configuration needed

**What breaks at 10x traffic:**
- More pods = more scrape targets
- Prometheus needs to scrape more frequently
- Solution: Increase scrape interval or use Prometheus federation

---

## Tradeoffs: Why Prometheus Over Alternatives

### Prometheus vs Datadog

**Prometheus:**
- ✅ **Free**: Open source, self-hosted
- ✅ **Kubernetes-native**: Built for K8s
- ✅ **Powerful queries**: PromQL is very expressive
- ❌ **Self-hosted**: You manage it
- ❌ **Limited retention**: Need external storage for long-term

**Datadog:**
- ✅ **Managed**: They handle everything
- ✅ **Long retention**: Years of data
- ✅ **More features**: APM, logs, traces
- ❌ **Expensive**: $15-31 per host/month
- ❌ **Vendor lock-in**: Hard to migrate

**Why we chose Prometheus:**
- Learning project (free is better)
- Kubernetes-native (fits our stack)
- Industry standard (used by many companies)
- Can migrate to managed later if needed

### Prometheus vs CloudWatch (AWS)

**Prometheus:**
- ✅ **Multi-cloud**: Works anywhere
- ✅ **Powerful queries**: PromQL
- ✅ **Kubernetes integration**: Auto-discovery
- ❌ **Self-hosted**: You manage it

**CloudWatch:**
- ✅ **Managed**: AWS handles it
- ✅ **Integrated**: Works with all AWS services
- ❌ **AWS-only**: Locked to AWS
- ❌ **Expensive**: Pay per metric, log, etc.
- ❌ **Less flexible**: Harder to customize

**Why we chose Prometheus:**
- Want to learn Kubernetes (not AWS-specific)
- Multi-cloud flexibility
- Industry standard

### Prometheus vs Grafana Cloud (Managed Prometheus)

**Self-hosted Prometheus (what we're doing):**
- ✅ **Free**: No cost
- ✅ **Full control**: Configure everything
- ✅ **Learning**: Understand how it works
- ❌ **Operational overhead**: You manage it
- ❌ **Limited retention**: 30 days

**Grafana Cloud:**
- ✅ **Managed**: They handle operations
- ✅ **Long retention**: Years of data
- ✅ **Grafana included**: Dashboards ready
- ❌ **Cost**: $8-50/month depending on usage
- ❌ **Less control**: Can't customize as much

**Why we chose self-hosted:**
- Learning project (understand how it works)
- Free (no cost)
- Can migrate to managed later

---

## What Breaks at 10x Traffic

### Scenario: Normal Traffic → 10x Spike

**Normal:**
- 100 requests/second
- 2 API Gateway pods
- 2 Wallet Service pods
- CPU: 30%
- Memory: 40%
- Response time: 200ms

**10x Traffic:**
- 1000 requests/second
- Same number of pods
- What happens?

### What Breaks and Why

**1. CPU Saturation**
```
Normal: CPU 30% (plenty of headroom)
10x:    CPU 100% (no headroom)
Result: Requests queue up, response time increases
```

**Why it breaks:**
- Each request needs CPU time
- 10x requests = 10x CPU needed
- But we have same number of pods
- CPU hits 100%, can't process faster

**How monitoring helps:**
- Alert: "CPU > 80% for 5 minutes"
- Action: Scale pods from 2 to 10
- Result: CPU back to 30%

**2. Database Connection Pool Exhaustion**
```
Normal: 10 connections (plenty available)
10x:    100 connections needed
Result: "Connection pool exhausted" errors
```

**Why it breaks:**
- Each request needs database connection
- Connection pool limited (e.g., 20 connections)
- 10x requests = need 10x connections
- Pool exhausted → Requests fail

**How monitoring helps:**
- Metric: `database_connections_active`
- Alert: "Connection pool > 80%"
- Action: Increase pool size or add read replicas

**3. Memory Pressure**
```
Normal: Memory 40% (2GB used of 5GB)
10x:   Memory 95% (4.75GB used)
Result: OOM kills, service restarts
```

**Why it breaks:**
- More requests = more memory per request
- Caching more data
- Memory fills up
- Kubernetes kills pod (OOM)

**How monitoring helps:**
- Alert: "Memory > 80% for 5 minutes"
- Action: Scale pods (distribute memory) or increase limits

**4. Queue Backlog**
```
Normal: Queue depth: 0-10 messages
10x:    Queue depth: 1000+ messages
Result: Transactions delayed by minutes
```

**Why it breaks:**
- Transaction service processes queue
- 10x transactions = 10x queue depth
- Processing can't keep up
- Queue backs up

**How monitoring helps:**
- Metric: `rabbitmq_queue_messages`
- Alert: "Queue depth > 100"
- Action: Scale transaction service workers

**5. Cache Eviction**
```
Normal: Cache hit rate: 95%
10x:    Cache hit rate: 60%
Result: More database load, slower responses
```

**Why it breaks:**
- Redis cache has limited memory
- 10x requests = 10x cache entries
- Cache fills up, evicts old entries
- More cache misses = more database queries

**How monitoring helps:**
- Metric: `cache_hit_rate`
- Alert: "Cache hit rate < 80%"
- Action: Increase Redis memory or scale Redis

### The Cascade Failure

**How one problem causes another:**

```
1. Traffic spike → CPU hits 100%
2. CPU 100% → Requests queue up
3. Queued requests → Timeout
4. Timeouts → Errors increase
5. Errors → Users retry
6. Retries → More traffic
7. More traffic → Worse performance
8. Worse performance → More errors
```

**This is why monitoring is critical:**
- Catch problem at step 1 (CPU high)
- Fix before cascade happens
- Prevent system-wide failure

---

## Deployment Guide

### Step 1: Understand What You're Deploying

**Prometheus Files:**
- `namespace.yaml` - Creates `monitoring` namespace (isolates monitoring from app)
- `prometheus-config.yaml` - Tells Prometheus what to scrape
- `prometheus-rules.yaml` - Defines when to alert
- `prometheus-deployment.yaml` - Runs Prometheus (pod, service, storage)

**Loki Files:**
- `loki-deployment.yaml` - Runs Loki (StatefulSet, service, storage, config)
  - ConfigMap: Loki configuration (retention, storage)
  - Service: Internal access to Loki
  - StatefulSet: Runs Loki with persistent storage
  - PVC: 100GB storage for logs (7-day retention)

### Step 2: Deploy

```bash
# Set kubeconfig (if not already set)
export KUBECONFIG=~/.kube/microk8s-config

# Deploy Prometheus
kubectl apply -f k8s/monitoring/prometheus-*.yaml

# Deploy Loki
kubectl apply -f k8s/monitoring/loki-deployment.yaml

# Or deploy everything at once
kubectl apply -f k8s/monitoring/

# Verify
kubectl get pods -n monitoring
```

**What happens:**
1. Namespace created (isolates monitoring resources)
2. Prometheus ConfigMaps created (config and alert rules)
3. Prometheus PVC created (50GB storage for metrics)
4. Prometheus Deployment created (pod, service)
5. Loki ConfigMap created (Loki configuration)
6. Loki StatefulSet created (pod, service, PVC for logs)

### Step 3: Verify It's Working

```bash
# Check pods are running
kubectl get pods -n monitoring

# Check Prometheus logs
kubectl logs -n monitoring -l app=prometheus --tail=20

# Check Loki logs
kubectl logs -n monitoring -l app=loki --tail=20

# Port-forward to access Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Open: http://localhost:9090

# Port-forward to access Loki API (for testing)
kubectl port-forward -n monitoring svc/loki 3100:3100
# Test: curl http://localhost:3100/ready
```

**In Prometheus UI:**
1. **Status → Targets**: Should see all SwiftPay services (green = scraping)
2. **Status → Configuration**: Should see your scrape configs
3. **Alerts**: Should see alert rules loaded
4. **Graph**: Try query: `rate(http_requests_total[5m])`

**Verify Loki:**
```bash
# Check Loki is ready
curl http://localhost:3100/ready
# Should return: ready

# Check Loki metrics
curl http://localhost:3100/metrics
```

**Note**: To actually collect logs, you need Promtail (log shipper). We'll add that next.

---

## Understanding the Code

### prometheus-config.yaml: How Scraping Works

```yaml
# This tells Prometheus: "Find all pods with app=api-gateway label"
scrape_configs:
  - job_name: 'api-gateway'
    kubernetes_sd_configs:  # Use Kubernetes service discovery
      - role: pod           # Discover pods (not services)
        namespaces:
          names: ['swiftpay'] # Only in swiftpay namespace
    relabel_configs:
      # Filter: Only keep pods with app=api-gateway label
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: api-gateway
        action: keep
      # Set target: Use pod IP and port 3000
      - source_labels: [__meta_kubernetes_pod_ip]
        target_label: __address__
        replacement: ${1}:3000
```

**What this does:**
1. Prometheus queries Kubernetes API: "Give me all pods in swiftpay namespace"
2. Kubernetes returns list of pods with metadata (labels, IPs)
3. Prometheus filters: Only pods where `app=api-gateway`
4. Prometheus scrapes: `http://pod-ip:3000/metrics` every 15 seconds

**Why this is powerful:**
- Auto-discovers new pods (when you scale)
- Auto-removes dead pods (when pods die)
- No manual configuration needed

### prometheus-rules.yaml: When to Alert

```yaml
- alert: HighErrorRate
  expr: rate(http_requests_total{code=~"5.."}[5m]) > 0.1
  for: 2m
  labels:
    severity: warning
```

**Breaking it down:**
- `rate(http_requests_total{code=~"5.."}[5m])` - Error rate over 5 minutes
- `> 0.1` - Greater than 10% (0.1 = 10%)
- `for: 2m` - Must be true for 2 minutes (prevents false alarms)
- `severity: warning` - Alert severity level

**What this means:**
- "If error rate > 10% for 2 minutes, fire alert"
- Prevents false alarms (spike for 10 seconds = no alert)
- Gives you time to investigate before it's critical

### prometheus-deployment.yaml: Running Prometheus

```yaml
containers:
  - name: prometheus
    image: prom/prometheus:latest
    args:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
```

**What each arg does:**
- `--config.file`: Where to find scrape configs
- `--storage.tsdb.path`: Where to store metrics (on persistent volume)
- `--storage.tsdb.retention.time=30d`: Keep metrics for 30 days

**Why 30 days:**
- Balance between storage cost and usefulness
- Most issues happen in last 7 days
- 30 days gives enough history for analysis
- Can extend with external storage (Thanos) if needed

---

## Key Takeaways

### The Big Picture

1. **Monitoring answers three questions**: What's broken? Why? How to prevent?
2. **Two pillars**: Metrics (Prometheus) + Logs (Loki) = Complete picture
3. **Four golden signals**: Latency, Traffic, Errors, Saturation
4. **Pull model**: Prometheus scrapes metrics, Promtail reads logs (simple, reliable)
5. **Time-series storage**: Both optimized for time-based queries
6. **Auto-discovery**: Kubernetes finds services automatically

### Metrics vs Logs: When to Use What

**Use Metrics (Prometheus) when:**
- You need numbers: CPU, memory, request rate, error rate
- You need aggregation: sum, average, rate over time
- You need alerts: "Error rate > 10%"
- You need dashboards: Graphs showing trends

**Use Logs (Loki) when:**
- You need context: "Why did this error happen?"
- You need details: Stack traces, debug messages
- You need correlation: "What happened around this time?"
- You need investigation: "Show me all errors from wallet-service"

**Together:**
- Metrics: "Error rate is 10%" (WHAT)
- Logs: "Error: Connection timeout to wallet-service" (WHY)
- Action: "Scale wallet service" (HOW TO FIX)

### Why This Matters

**Without monitoring:**
- You're blind to problems
- Users report issues (too late)
- You guess at solutions
- System breaks at scale

**With monitoring:**
- You see problems before users
- You know exactly what's wrong
- You can prevent issues
- System scales gracefully

### The Mental Model

Think of monitoring like a car dashboard:
- **Speed** = Request rate
- **RPM** = CPU usage
- **Fuel** = Memory/Resources
- **Temperature** = Error rate
- **Warning lights** = Alerts

When something looks wrong, you investigate. Same with monitoring.

---

## Next Steps

1. **Deploy Promtail**: Log shipper to collect logs from pods
2. **Explore Prometheus UI**: Query metrics, see trends
3. **Set up Grafana**: Visualize metrics AND logs together
4. **Configure AlertManager**: Send alerts to Slack/Email
5. **Add more metrics**: Business metrics, custom metrics
6. **Plan for scale**: What breaks at 100x traffic?

### What's Missing: Promtail

**Promtail** is the log shipper that collects logs from pods and sends them to Loki.

**Why we need it:**
- Pods write logs to stdout/stderr
- Promtail reads these logs (via Kubernetes API)
- Promtail adds labels (pod name, namespace, app)
- Promtail sends logs to Loki

**Without Promtail:**
- Loki is running but has no logs
- You'd have to manually send logs to Loki
- No automatic log collection

**With Promtail:**
- Automatic log collection from all pods
- Labels added automatically
- Logs flow to Loki seamlessly

We'll add Promtail deployment next to complete the logging stack.

---

*Monitoring isn't about graphs—it's about understanding your system and preventing problems before they happen.*
