# Runbook — Operate & Debug SwiftPay

## Health Check (First Thing to Run)

```bash
# Is everything running?
kubectl get pods -A
docker-compose ps  # local

# Are services responding?
curl http://localhost:3000/health  # API Gateway
curl http://localhost:3004/health  # Auth
curl http://localhost:3001/health  # Wallet
curl http://localhost:3002/health  # Transaction
curl http://localhost:3003/health  # Notification
```

**Expected response:**
```json
{
  "status": "healthy",
  "service": "api-gateway",
  "timestamp": "2026-01-13T18:00:00.000Z"
}
```

## Common Issues & Exact Fixes

### Frontend → API Gateway Connection Fails (70% of issues)

**Symptom:** Browser shows "Failed to fetch" or 404 errors when calling API

**Cause:** Nginx proxy_pass misconfigured or API Gateway service name wrong

**Fix:**
```bash
# Docker Compose
docker-compose exec frontend cat /etc/nginx/conf.d/default.conf | grep proxy_pass
# Should show: proxy_pass http://api-gateway:80;

# Kubernetes
kubectl get configmap frontend-nginx -n swiftpay -o yaml | grep proxy_pass
# Should show: proxy_pass $api_gateway; (with variable for DNS resolution)

# Test connection
docker-compose exec frontend wget -qO- http://api-gateway:80/health
kubectl exec -it <frontend-pod> -n swiftpay -- wget -qO- http://api-gateway.swiftpay.svc.cluster.local:80/health
```

### Transactions Stuck in PENDING

**Symptom:** Transactions stay in PENDING status, never process

**Cause:** RabbitMQ down, worker crashed, or message not queued

**Fix:**
```bash
# Check RabbitMQ is running
kubectl get pods -n swiftpay | grep rabbitmq
docker-compose ps rabbitmq

# Check transaction service logs
kubectl logs deployment/transaction-service -n swiftpay | grep -i rabbitmq
docker-compose logs transaction-service | grep -i rabbitmq

# Check queue depth
curl http://localhost:15672/api/queues/%2F/transactions  # RabbitMQ Management API
# Or: kubectl port-forward svc/rabbitmq 15672:15672

# Restart transaction service (will reconnect to RabbitMQ)
kubectl rollout restart deployment/transaction-service -n swiftpay
docker-compose restart transaction-service
```

### All Transactions Failing

**Symptom:** Transactions go PENDING → PROCESSING → FAILED

**Cause:** Wallet Service down, database connection lost, or insufficient funds

**Fix:**
```bash
# Check wallet service health
kubectl get pods -n swiftpay -l app=wallet-service
docker-compose ps wallet-service

# Check wallet service logs
kubectl logs deployment/wallet-service -n swiftpay --tail=50
docker-compose logs wallet-service --tail=50

# Check database connection
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c "SELECT 1"
docker-compose exec postgres psql -U swiftpay -d swiftpay -c "SELECT 1"

# Check circuit breaker state
curl http://localhost:3002/metrics | grep circuit_breaker_state
# If open (1), wallet service is down - restart it
```

### RabbitMQ Connection Timeout

**Symptom:** Transaction service logs show "ETIMEDOUT" connecting to RabbitMQ

**Cause:** RabbitMQ pod missing, network policy blocking, or wrong URL

**Fix:**
```bash
# Check RabbitMQ pod exists
kubectl get pods -n swiftpay | grep rabbitmq
# If missing, deploy it:
kubectl apply -f k8s/infrastructure/rabbitmq.yaml

# Check network policies
kubectl get networkpolicies -n swiftpay
# May need to allow traffic from transaction-service to rabbitmq

# Verify RabbitMQ URL in transaction service
kubectl get configmap app-config -n swiftpay -o yaml | grep RABBITMQ_URL
# Should be: amqp://swiftpay:swiftpay123@rabbitmq:5672 (local) or service DNS (k8s)
```

### Database Connection Refused

**Symptom:** Services can't connect to PostgreSQL

**Cause:** PostgreSQL down, wrong connection string, or network issue

**Fix:**
```bash
# Check PostgreSQL is running
kubectl get pods -n swiftpay | grep postgres
docker-compose ps postgres

# Check PostgreSQL logs
kubectl logs postgres-0 -n swiftpay --tail=50
docker-compose logs postgres --tail=50

# Test connection from service pod
kubectl exec -it deployment/auth-service -n swiftpay -- \
  psql -h postgres -U swiftpay -d swiftpay -c "SELECT 1"

# Verify connection string
kubectl get configmap app-config -n swiftpay -o yaml | grep DB_HOST
```

## Tracing a Failed Transaction

```bash
# 1. Get transaction ID from user or database
kubectl exec postgres-0 -n swiftpay -- psql -U swiftpay -d swiftpay -c \
  "SELECT id, status, error_message, created_at FROM transactions WHERE id = 'TXN-123';"

# 2. Check API Gateway logs (request entry point)
kubectl logs deployment/api-gateway -n swiftpay | grep TXN-123

# 3. Check transaction service logs (creation and processing)
kubectl logs deployment/transaction-service -n swiftpay | grep TXN-123

# 4. Check wallet service logs (money transfer)
kubectl logs deployment/wallet-service -n swiftpay | grep TXN-123

# 5. Check notification service logs (email/SMS)
kubectl logs deployment/notification-service -n swiftpay | grep TXN-123

# 6. Check RabbitMQ queue (if stuck)
curl -u swiftpay:swiftpay123 http://localhost:15672/api/queues/%2F/transactions
# Look for messageCount > 0
```

**Common failure points:**
- API Gateway: Authentication failed, rate limit exceeded
- Transaction Service: RabbitMQ connection failed, database write failed
- Wallet Service: Insufficient funds, database transaction failed
- RabbitMQ: Message not consumed (worker down)

## Monitoring

### Access Grafana

```bash
# Port forward to local machine
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# Open browser
open http://localhost:3000
# Default credentials: admin/admin (change on first login)
```

**Key dashboards:**
- Service Health: All services up/down status
- Request Rate: Requests per second per service
- Error Rate: 4xx/5xx errors per service
- Database Connections: Active PostgreSQL connections
- Queue Depth: RabbitMQ message count

### Access RabbitMQ Management UI

```bash
# Local
open http://localhost:15672
# Credentials: swiftpay/swiftpay123

# Kubernetes
kubectl port-forward svc/rabbitmq 15672:15672 -n swiftpay
open http://localhost:15672
```

**What to check:**
- Queue depth: `transactions` queue should be < 100 messages
- Consumer count: Should match number of transaction service pods
- Message rate: Messages/second (in/out)
- Dead letter queue: `transactions.dlq` should be empty (or investigate if not)

### Prometheus Metrics

```bash
# Query metrics endpoint
curl http://localhost:3000/metrics | grep http_requests_total
curl http://localhost:3002/metrics | grep transactions_total
curl http://localhost:3001/metrics | grep transfers_total
```

## Cluster Access

### SSH to Bastion and Connect to EKS

```bash
# SSH to bastion
ssh -i ~/.ssh/swiftpay-bastion-key.pem ec2-user@<bastion-ip>

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name swiftpay-eks-cluster

# Verify access
kubectl get nodes
kubectl get pods -n swiftpay
```

### SSH to Bastion and Connect to AKS

```bash
# SSH to bastion
ssh -i ~/.ssh/swiftpay-azure-key.pem azureuser@<bastion-ip>

# Configure kubectl
az login
az aks get-credentials --resource-group swiftpay-rg --name swiftpay-aks-cluster

# Verify access
kubectl get nodes
```

## Useful Commands Quick Reference

```bash
# Scale a service
kubectl scale deployment/transaction-service --replicas=3 -n swiftpay

# Get logs (last 100 lines)
kubectl logs --tail=100 deployment/api-gateway -n swiftpay

# Follow logs (real-time)
kubectl logs -f deployment/transaction-service -n swiftpay

# Exec into a pod
kubectl exec -it deployment/wallet-service -n swiftpay -- sh

# Check resource usage
kubectl top pods -n swiftpay
kubectl top nodes

# Check events (what just happened)
kubectl get events -n swiftpay --sort-by='.lastTimestamp'

# Check service endpoints
kubectl get endpoints -n swiftpay

# Check ingress
kubectl get ingress -n swiftpay

# Restart a deployment
kubectl rollout restart deployment/api-gateway -n swiftpay

# Check deployment status
kubectl rollout status deployment/transaction-service -n swiftpay

# View pod details
kubectl describe pod <pod-name> -n swiftpay

# Check secrets
kubectl get secrets -n swiftpay
kubectl get secret app-secrets -n swiftpay -o yaml
```

