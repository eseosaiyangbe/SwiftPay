# Troubleshooting Guide — Deep Reference

> **When to read this:** You've hit an error that isn't covered by the quick-fix table in [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) at the repo root. This is the long-form version with narrative explanations, underlying concepts, and real-world failure stories.
>
> **Quick fixes first:** Check [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) (root) — it's symptom → root cause → exact fix in one place.
>
> **Which doc for deploy vs runtime?** [Documentation index](README.md).

---

## The Most Common Issue: Frontend → API Gateway URL

**If requests fail, 70% of the time the problem is here.**

### Correct Mental Model

- **Frontend NEVER talks to services directly**
- **Frontend ONLY talks to API Gateway**
- **Nginx proxies `/api/*` → `api-gateway`**

### Symptoms

If you see:
- 404 from frontend
- Network error in browser
- "Failed to fetch" error
- API works via curl but not UI

**The problem is almost certainly the frontend → API Gateway connection.**

### Check in This Order

**1. Frontend nginx.conf proxy_pass**

The frontend's nginx configuration must proxy `/api/*` requests to the API Gateway:

```nginx
location /api {
    # Docker Compose: Use service name
    proxy_pass http://api-gateway:80;
    
    # Kubernetes: Use full FQDN with variable (prevents startup failures)
    set $api_gateway "http://api-gateway.payflow.svc.cluster.local:80";
    proxy_pass $api_gateway;
}
```

**Why the variable in Kubernetes?** Nginx tries to resolve hostnames at startup. If `api-gateway` isn't ready yet, nginx fails. Using a variable forces DNS resolution at request time.

**2. API Gateway Service Name**

Check that the service name matches:
- Docker Compose: `api-gateway` (from docker-compose.yml)
- Kubernetes: `api-gateway` (from service YAML)

**3. Docker / K8s Service DNS**

**Docker Compose:**
```bash
# Test from frontend container
docker-compose exec frontend wget -qO- http://api-gateway:80/health
```

**Kubernetes:**
```bash
# Test from frontend pod
kubectl exec -it <frontend-pod> -n payflow -- wget -qO- http://api-gateway.payflow.svc.cluster.local:80/health
```

**4. Port Alignment**

- Frontend nginx listens on port 80
- API Gateway listens on port 80 (container port)
- Service exposes port 80 (Kubernetes)

**Common Mistake:** Using port 3000 in nginx.conf when API Gateway is on port 80.

### Quick Fix

**Docker Compose:**
```bash
# Check nginx config
docker-compose exec frontend cat /etc/nginx/conf.d/default.conf | grep proxy_pass

# Should show: proxy_pass http://api-gateway:80;
```

**Kubernetes:**
```bash
# Check nginx config in ConfigMap
kubectl get configmap frontend-nginx -n payflow -o yaml | grep proxy_pass

# Should show: proxy_pass $api_gateway; (with variable)
```

### Why This Happens

Beginners often think:
- "Frontend can call services directly" (wrong)
- "I'll just change the API URL" (wrong - frontend doesn't know service URLs)
- "Nginx is just serving files" (wrong - nginx also proxies API calls)

**The reality:** Frontend is a React app. It makes requests to `/api/*`. Nginx intercepts these and proxies them to the API Gateway. The API Gateway then routes to the correct service.

**If nginx isn't configured correctly, the frontend can't reach the backend.**

---

## Table of Contents

1. [The Most Common Issue: Frontend → API Gateway URL](#the-most-common-issue-frontend--api-gateway-url) ← Start here if requests fail
2. [General Troubleshooting](#general-troubleshooting)
3. [Docker Issues](#docker-issues)
4. [Kubernetes Issues](#kubernetes-issues)
5. [Application Issues](#application-issues)
6. [Network Issues](#network-issues)
7. [Getting Help](#getting-help)

---

## General Troubleshooting

### Step 1: Check Logs

**Always start here!** Logs tell you what's wrong.

**Docker Compose:**
```bash
# View all logs
docker-compose logs

# View specific service
docker-compose logs frontend

# Follow logs (real-time)
docker-compose logs -f
```

**Kubernetes:**
```bash
# View pod logs
kubectl logs <pod-name> -n payflow

# View service logs
kubectl logs -l app=frontend -n payflow

# View previous container logs (if crashed)
kubectl logs <pod-name> -n payflow --previous
```

**What to look for:**
- Error messages
- Connection failures
- Timeout errors
- Missing dependencies

---

### Step 2: Check Status

**Docker Compose:**
```bash
# Check if containers are running
docker-compose ps

# Check container status
docker ps
```

**Kubernetes:**
```bash
# Check pods
kubectl get pods -n payflow

# Check services
kubectl get svc -n payflow

# Check deployments
kubectl get deployments -n payflow
```

**What to look for:**
- Containers/pods not running
- CrashLoopBackOff status
- Pending status
- Error states

---

### Step 3: Check Resources

**Docker:**
```bash
# Check Docker resources
docker stats
```

**Kubernetes:**
```bash
# Check resource usage
kubectl top pods -n payflow
kubectl top nodes
```

**What to look for:**
- High CPU usage
- High memory usage
- Resource limits reached

---

## Docker Issues

### Issue: Port Already in Use

**Error:**
```
Error: bind: address already in use
```

**Cause:** Another application is using the port

**Solution:**
```bash
# Find what's using the port (macOS/Linux)
lsof -i :3000

# Kill the process
kill -9 <PID>

# Or change port in docker-compose.yml
ports:
  - "3001:3000"  # Use port 3001 instead
```

---

### Issue: Container Won't Start

**Error:**
```
Container keeps restarting
```

**Diagnosis:**
```bash
# Check logs
docker-compose logs <service-name>

# Check container status
docker ps -a
```

**Common Causes:**

**1. Application Error**
- Check logs for error messages
- Fix code error
- Restart container

**2. Missing Dependencies**
- Check if database is running
- Check if Redis is running
- Check if RabbitMQ is running

**3. Configuration Error**
- Check environment variables
- Check configuration files

**Solution:**
```bash
# Restart service
docker-compose restart <service-name>

# Rebuild and restart
docker-compose up -d --build <service-name>
```

---

### Issue: Can't Connect to Database

**Error:**
```
Connection refused
Connection timeout
```

**Diagnosis:**
```bash
# Check if database is running
docker-compose ps postgres

# Check database logs
docker-compose logs postgres

# Test connection
docker-compose exec postgres psql -U payflow -d payflow
```

**Common Causes:**

**1. Database Not Running**
```bash
# Start database
docker-compose up -d postgres

# Wait for it to be ready
docker-compose exec postgres pg_isready -U payflow
```

**2. Wrong Connection String**
- Check environment variables
- Check database name, user, password

**3. Network Issue**
- Check if services are on same network
- Check docker-compose.yml network configuration

**Solution:**
```bash
# Restart all services
docker-compose down
docker-compose up -d
```

---

### Issue: Image Build Fails

**Error:**
```
Failed to build image
```

**Diagnosis:**
```bash
# Build with verbose output
docker-compose build --no-cache <service-name>

# Check Dockerfile
cat services/<service-name>/Dockerfile
```

**Common Causes:**

**1. Missing Files**
- Check if all files are copied
- Check .dockerignore

**2. Dependency Installation Fails**
- Check package.json
- Check npm registry

**3. Build Context Issues**
- Check Dockerfile paths
- Check build context

**Solution:**
```bash
# Clean build
docker-compose build --no-cache <service-name>

# Rebuild all
docker-compose build --no-cache
```

---

## Kubernetes Issues

### Issue: Pod in CrashLoopBackOff

**Error:**
```
STATUS: CrashLoopBackOff
```

**Diagnosis:**
```bash
# Check pod status
kubectl describe pod <pod-name> -n payflow

# Check logs
kubectl logs <pod-name> -n payflow

# Check previous container logs
kubectl logs <pod-name> -n payflow --previous
```

**Common Causes:**

**1. Application Error**
- Check logs for error messages
- Fix code error
- Rebuild image

**2. Missing Dependencies**
- Check if database is running
- Check if ConfigMap exists
- Check if Secret exists

**3. Resource Limits**
- Check if pod has enough resources
- Check resource quotas

**Solution:**
```bash
# Delete pod (will recreate)
kubectl delete pod <pod-name> -n payflow

# Restart deployment
kubectl rollout restart deployment/<deployment-name> -n payflow
```

---

### Real-World Example: Auth Service Crash Loop - The Hidden Dependency

> **The Story**: Auth service kept crashing, but the error message didn't tell the whole story. Here's how we discovered the real problem.

#### The Symptom

You check your auth service and see:
```bash
kubectl get pods -n payflow -l app=auth-service
```

**Output:**
```
NAME                            READY   STATUS             RESTARTS   AGE
auth-service-56cc7b7488-79472   0/1     CrashLoopBackOff   157        35h
auth-service-56cc7b7488-7zhsj   0/1     CrashLoopBackOff   258        10d
```

**What you think**: "Auth service is broken. Let me check the logs."

#### Step 1: Check the Logs (The Red Herring)

```bash
kubectl logs -n payflow deployment/auth-service --tail=50
```

**What you see:**
```
Auth service running on port 3004
Error: getaddrinfo ENOTFOUND postgres
    at /app/node_modules/pg-pool/index.js:45:11
    ...
    code: 'ENOTFOUND',
    hostname: 'postgres'
```

**What you think**: "PostgreSQL isn't running. That's the problem!"

**But wait...** The error says it can't find `postgres`, but that doesn't mean PostgreSQL isn't running. It could mean:
1. PostgreSQL pod doesn't exist
2. PostgreSQL service doesn't exist
3. DNS isn't working
4. PostgreSQL pod exists but isn't ready

#### Step 2: Check PostgreSQL Status (The Real Investigation)

```bash
# Check if PostgreSQL pod exists
kubectl get pods -n payflow | grep postgres

# Output: (empty - no pods!)
```

**Aha!** No PostgreSQL pods are running. But why?

```bash
# Check StatefulSet status
kubectl get statefulset postgres -n payflow

# Output:
# NAME       READY   AGE
# postgres   0/1     14d
```

**StatefulSet exists but has 0/1 ready.** This means Kubernetes is trying to create the pod but failing.

#### Step 3: Find the Real Problem (The Hidden Issue)

```bash
# Check StatefulSet events
kubectl describe statefulset postgres -n payflow | tail -20
```

**The smoking gun:**
```
Events:
  Type     Reason        Age                   From                    Message
  ----     ------        ----                  ----                    -------
  Warning  FailedCreate  5m9s (x2 over 5m10s)  statefulset-controller  
  create Pod postgres-0 in StatefulSet postgres failed error: 
  pods "postgres-0" is forbidden: exceeded quota: payflow-resource-quota, 
  requested: limits.cpu=1,requests.cpu=250m, 
  used: limits.cpu=7900m,requests.cpu=3900m, 
  limited: limits.cpu=8,requests.cpu=4
```

**The real problem**: PostgreSQL StatefulSet doesn't have resource requests/limits defined, but the resource quota requires them. Kubernetes can't create the pod because it would exceed the quota.

**Why this happens**: When you set up resource quotas (which is a good security practice), ALL pods must specify resource requests and limits. If even one pod is missing them, Kubernetes won't create it.

#### Step 4: Check Resource Quota (Understanding the Constraint)

```bash
# Check current quota usage
kubectl get resourcequota payflow-resource-quota -n payflow -o yaml
```

**What you see:**
- **Quota limit**: 4 CPU requests, 8 CPU limits
- **Currently used**: 3900m CPU requests, 7900m CPU limits
- **Available**: Only 100m CPU requests, 100m CPU limits left

**The math**: 
- PostgreSQL tried to request 250m CPU (requests) and 1000m CPU (limits)
- But only 100m is available
- Kubernetes said "No" and refused to create the pod

#### Step 5: The Fix (Adding Resource Limits)

**Edit the PostgreSQL StatefulSet** (`k8s/infrastructure/postgres.yaml`):

**Before** (missing resources):
```yaml
containers:
- name: postgres
  image: postgres:15-alpine
  # ... no resources section ...
```

**After** (with resources):
```yaml
containers:
- name: postgres
  image: postgres:15-alpine
  # ... other config ...
  resources:
    requests:
      cpu: "100m"      # Minimum CPU guarantee (fits within quota)
      memory: "256Mi"  # Minimum memory guarantee
    limits:
      cpu: "100m"      # Maximum CPU limit (fits within quota)
      memory: "512Mi"  # Maximum memory limit
```

**Apply the fix:**
```bash
kubectl apply -f k8s/infrastructure/postgres.yaml
```

#### Step 6: Verify PostgreSQL Starts

```bash
# Wait a few seconds, then check
kubectl get pods -n payflow -l app=postgres

# Output:
# NAME         READY   STATUS    RESTARTS   AGE
# postgres-0   1/1     Running   0          81s
```

**Success!** PostgreSQL is now running.

#### Step 7: Auth Service Recovers Automatically

Once PostgreSQL is running, auth service automatically recovers:

```bash
# Check auth service (wait 10-15 seconds)
kubectl get pods -n payflow -l app=auth-service

# Output:
# NAME                            READY   STATUS    RESTARTS   AGE
# auth-service-56cc7b7488-nvv6x   1/1     Running   0          73s
# auth-service-56cc7b7488-pnd6r   1/1     Running   0          43s
```

**Verify it's working:**
```bash
kubectl logs -n payflow deployment/auth-service --tail=10

# Output:
# Auth service running on port 3004
# Auth database initialized
# ::ffff:192.168.64.2 - - [08/Jan/2026:18:04:25 +0000] "GET /health HTTP/1.1" 200 88
```

**Perfect!** Auth service is healthy and connected to the database.

#### The Lesson

**What we learned:**
1. **Error messages can be misleading**: "ENOTFOUND postgres" made us think PostgreSQL wasn't running, but the real issue was that PostgreSQL couldn't start.
2. **Resource quotas are strict**: If a quota requires resource limits, ALL pods must have them, or they won't be created.
3. **Check dependencies first**: When a service crashes, check if its dependencies (like databases) are actually running, not just if they exist.
4. **Read the events**: `kubectl describe` shows events that explain WHY something failed, not just THAT it failed.

**Quick diagnostic checklist for crash loops:**
1. ✅ Check pod logs: `kubectl logs <pod-name> -n payflow`
2. ✅ Check pod status: `kubectl describe pod <pod-name> -n payflow`
3. ✅ Check dependencies: Are databases/services it needs actually running?
4. ✅ Check resource quotas: `kubectl get resourcequota -n payflow`
5. ✅ Check events: `kubectl get events -n payflow --sort-by='.lastTimestamp'`

**Prevention tip**: Always add resource requests and limits to ALL pods, especially when using resource quotas. It's a best practice anyway!

---

### Issue: Pod in Pending State

**Error:**
```
STATUS: Pending
```

**Diagnosis:**
```bash
# Check why pod is pending
kubectl describe pod <pod-name> -n payflow

# Look for events
kubectl get events -n payflow
```

**Common Causes:**

**1. Insufficient Resources**
- Node doesn't have enough CPU/memory
- Check resource requests

**2. Image Pull Error**
- Image doesn't exist
- Can't pull from registry

**3. Node Not Ready**
- Node is down
- Check node status

**Solution:**
```bash
# Check nodes
kubectl get nodes

# Check resource usage
kubectl top nodes

# Check image
kubectl describe pod <pod-name> -n payflow | grep Image
```

---

### Issue: Service Not Accessible

**Error:**
```
Connection refused
Service unavailable
```

**Diagnosis:**
```bash
# Check service
kubectl get svc -n payflow

# Check endpoints
kubectl get endpoints -n payflow

# Test from pod
kubectl exec -it <pod-name> -n payflow -- wget -qO- http://<service-name>:<port>/health
```

**Common Causes:**

**1. No Pods Running**
- Service has no backend pods
- Check deployment

**2. Wrong Port**
- Service port doesn't match pod port
- Check service and deployment ports

**3. Network Policy**
- Network policy blocking traffic
- Check network policies

**Solution:**
```bash
# Check pods
kubectl get pods -n payflow -l app=<service-name>

# Check service configuration
kubectl get svc <service-name> -n payflow -o yaml

# Check network policies
kubectl get networkpolicies -n payflow
```

---

### Issue: Image Pull Error

**Error:**
```
ImagePullBackOff
ErrImagePull
```

**Diagnosis:**
```bash
# Check image name
kubectl describe pod <pod-name> -n payflow | grep Image

# Check image pull policy
kubectl get deployment <deployment-name> -n payflow -o yaml | grep imagePullPolicy
```

**Common Causes:**

**1. Image Doesn't Exist**
- Image not built
- Image not pushed to registry

**2. Wrong Image Name**
- Typo in image name
- Wrong registry

**3. Authentication Required**
- Private registry needs credentials
- Check imagePullSecrets

**Solution:**
```bash
# Build and push image
docker build -t <image-name> .
docker push <image-name>

# Update deployment
kubectl set image deployment/<deployment-name> <container-name>=<image-name> -n payflow
```

---

## Application Issues

### Issue: Login Fails

**Symptoms:**
- "Invalid credentials" error
- 401 Unauthorized
- Can't log in

**Diagnosis:**
```bash
# Check auth service logs
docker-compose logs auth-service
# or
kubectl logs -l app=auth-service -n payflow

# Check database
docker-compose exec postgres psql -U payflow -d payflow -c "SELECT * FROM users;"
```

**Common Causes:**

**1. User Doesn't Exist**
- User not created
- Wrong email

**2. Password Hash Mismatch**
- Password hashing issue
- Check password validation

**3. Database Connection**
- Can't connect to database
- Check database logs

**Solution:**
```bash
# Create test user
curl -X POST http://localhost:3000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"Test123!","name":"Test User"}'

# Check if user exists
docker-compose exec postgres psql -U payflow -d payflow -c "SELECT email FROM users;"
```

---

### Issue: Transactions Fail

**Symptoms:**
- Transactions show "Failed" status
- Money not transferred
- Error messages

**Diagnosis:**
```bash
# Check transaction service logs
docker-compose logs transaction-service
# or
kubectl logs -l app=transaction-service -n payflow

# Check wallet service logs
docker-compose logs wallet-service
# or
kubectl logs -l app=wallet-service -n payflow

# Check RabbitMQ
docker-compose logs rabbitmq
# or
kubectl logs -l app=rabbitmq -n payflow
```

**Common Causes:**

**1. Wallet Service Unavailable**
- Can't reach wallet service
- Check network policies (Kubernetes)

**2. RabbitMQ Connection**
- Can't connect to RabbitMQ
- Check RabbitMQ logs

**3. Database Transaction**
- Database transaction fails
- Check database logs

**Solution:**
```bash
# Check service connectivity
docker-compose exec transaction-service wget -qO- http://wallet-service:3001/health

# Check RabbitMQ
docker-compose exec rabbitmq rabbitmqctl status

# Check database
docker-compose exec postgres psql -U payflow -d payflow -c "SELECT * FROM transactions ORDER BY created_at DESC LIMIT 5;"
```

---

### Issue: Frontend Can't Reach Backend

**Symptoms:**
- "Failed to fetch" error
- Network error
- 404 Not Found

**Diagnosis:**
```bash
# Check frontend logs
docker-compose logs frontend
# or
kubectl logs -l app=frontend -n payflow

# Check API Gateway
docker-compose logs api-gateway
# or
kubectl logs -l app=api-gateway -n payflow

# Test API directly
curl http://localhost:3000/api/health
```

**Common Causes:**

**1. API Gateway Not Running**
- API Gateway container not running
- Check container status

**2. Wrong API URL**
- Frontend using wrong URL
- Check REACT_APP_API_URL

**3. Network Issue**
- Services can't communicate
- Check docker network (Docker) or network policies (Kubernetes)

**Solution:**
```bash
# Check API Gateway
docker-compose ps api-gateway
# or
kubectl get pods -n payflow -l app=api-gateway

# Test API
curl http://localhost:3000/api/health

# Check frontend configuration
docker-compose exec frontend cat /usr/share/nginx/html/static/js/*.js | grep API_URL
```

---

## Network Issues

### Issue: Services Can't Communicate (Docker)

**Symptoms:**
- Connection refused
- Timeout errors

**Diagnosis:**
```bash
# Check network
docker network ls
docker network inspect <network-name>

# Test connectivity
docker-compose exec <service-1> ping <service-2>
```

**Solution:**
```bash
# Restart services
docker-compose down
docker-compose up -d

# Check if services are on same network
docker-compose ps
```

---

### Issue: Services Can't Communicate (Kubernetes)

**Symptoms:**
- Connection refused
- Timeout errors

**Diagnosis:**
```bash
# Check network policies
kubectl get networkpolicies -n payflow

# Test connectivity
kubectl exec -it <pod-1> -n payflow -- wget -qO- http://<service-2>:<port>/health
```

**Common Causes:**

**1. Network Policy Blocking**
- Network policy too restrictive
- Check network policies

**2. Service Not Found**
- Service DNS not resolving
- Check service name

**Solution:**
```bash
# Check network policies
kubectl describe networkpolicy <policy-name> -n payflow

# Temporarily remove network policies (for testing)
kubectl delete networkpolicies --all -n payflow

# Re-apply network policies
kubectl apply -f k8s/policies/network-policies.yaml
```

---

## Getting Help

### Before Asking for Help

1. **Check Logs**: Always check logs first
2. **Search Error**: Google the error message
3. **Check Documentation**: Read relevant docs
4. **Reproduce**: Can you reproduce the issue?

### When Asking for Help

**Include:**
- Error message (full error)
- Logs (relevant log output)
- Steps to reproduce
- What you've tried
- Environment (Docker, Kubernetes, etc.)

**Example:**
```
Issue: Login fails with "Connection refused"

Environment: Docker Compose
Steps:
1. docker-compose up -d
2. Try to login
3. Get "Connection refused" error

Logs:
[api-gateway] Error: connect ECONNREFUSED auth-service:3004

What I tried:
- Restarted services
- Checked docker-compose.yml
- Verified auth-service is running
```

---

## Summary

✅ **Troubleshooting Steps:**
1. Check logs
2. Check status
3. Check resources
4. Identify cause
5. Apply fix
6. Verify fix

**Remember:**
- **Logs are your friend**: They tell you what's wrong
- **Start simple**: Check if services are running
- **Isolate the issue**: Is it one service or all services?
- **Document solutions**: Write down what worked

**Next**: 
- Read [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) (root) for a quick symptom → fix table covering Docker, K8s, EKS, AKS, and CI
- Read [Kubernetes Deployment Guide](./microk8s-deployment.md) for the full MicroK8s walkthrough

---

*Most issues can be solved by checking logs and status! 🔍*

