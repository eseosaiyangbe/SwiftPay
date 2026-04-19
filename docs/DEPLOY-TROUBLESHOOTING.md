# SwiftPay EKS Deploy — Troubleshooting & Deep Scan Summary

> **Navigation:** Quick fixes → [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) (repo root). Full doc map → [Documentation index](README.md). This file is a **deploy/EKS-focused** pass summary and historical fixes.

## Issues found and fixed (this pass)

### 1. Health checks causing CrashLoopBackOff
- **Cause:** Auth and wallet `/health` returned 503 when Redis was unreachable (timeout or connection error). Kubernetes marks the pod unhealthy and restarts it.
- **Fix:** Health now returns 200 with `redis: 'disconnected'` when only Redis is down; 503 only when DB is down. Redis ping uses a 2s timeout so the handler doesn’t hang.
- **Files:** `services/auth-service/server.js`, `services/wallet-service/server.js`

### 2. Unhandled Redis connect rejection
- **Cause:** Auth and transaction services call `redisClient.connect()` without `.catch()`. If Redis is unreachable, the promise rejects and can terminate the process (unhandled rejection).
- **Fix:** Added `.catch()` so connect failures are logged and the app keeps running.
- **Files:** `services/auth-service/server.js`, `services/transaction-service/server.js`

### 3. Build and push workflow
- **Added:** `scripts/build-push-ecr.sh [IMAGE_TAG]` to build all images (context: `services/`) and push to ECR. Default tag: `v5`.
- **Usage:** `./scripts/build-push-ecr.sh v5` then `IMAGE_TAG=v5 ./deploy.sh` from `k8s/overlays/eks`.

### 4. Terraform RDS/Redis security groups
- **Note:** ElastiCache already uses the same SG list as RDS (`local.rds_allowed_sgs` in `terraform/aws/managed-services`). If you add `additional_rds_security_group_ids` in `terraform.tfvars`, both RDS and Redis get those SGs.
- **Doc:** `terraform/aws/managed-services/terraform.tfvars.example` and `scripts/README.md` describe this.

---

## Deep scan checklist (verified)

| Check | Status |
|-------|--------|
| All services use `require('./shared/...')` (not `../shared`) for container runtime | OK |
| All Dockerfiles use `COPY shared ./shared` | OK |
| `prom-client` in `dependencies` (not only devDependencies) where shared metrics are used | OK (auth-service fixed earlier) |
| No duplicate `http_requests_total` or `collectDefaultMetrics` in services | OK (shared/metrics.js only) |
| Frontend has `/health` (nginx) for liveness | OK |

---

## If pods still fail after fixes

### Pods in CrashLoopBackOff or Error

1. **Check why the container failed**
   ```bash
   kubectl describe pod <pod-name> -n swiftpay
   kubectl logs <pod-name> -n swiftpay --previous
   ```
   - **ImagePullBackOff:** Image missing or wrong tag in ECR. Push images with the tag in your overlay (e.g. `v5`): `./scripts/build-push-ecr.sh v5`.
   - **CrashLoopBackOff:** Process exits after start. Check logs for: missing env, DB/Redis connection refused, missing `db-secrets` (External Secrets not synced), or health check failing.

2. **Ensure db-secrets exists (EKS)**
   ```bash
   kubectl get secret db-secrets -n swiftpay
   kubectl get externalsecret -n swiftpay
   ```
   If `db-secrets` is missing or empty, fix the External Secret (AWS Secrets Manager keys: `swiftpay/dev/rds`, `swiftpay/dev/app/secrets`, `swiftpay/dev/rabbitmq`).

3. **Rebuild and push images**  
   Run `./scripts/build-push-ecr.sh v5` and deploy with `IMAGE_TAG=v5`.

4. **Confirm RDS/Redis reachability**  
   - Managed-services Terraform must allow EKS node (and cluster) SGs to RDS (5432) and ElastiCache (6379).  
   - Set `additional_rds_security_group_ids` if you have multiple node SGs.

5. **Inspect logs**  
   `kubectl logs deployment/<service> -n swiftpay --tail=100` and check for module not found, metric already registered, or connection timeouts.

6. **Deploy script “silent” failure**  
   Run with `DEBUG=1 ./deploy.sh` and/or check SSM command output in AWS Systems Manager for the bastion.
