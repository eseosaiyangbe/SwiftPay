# SwiftPay scripts

## Smoke tests

Run these from the repo root while Docker Compose is up:

```bash
./scripts/docker-storage-check.sh
npm run smoke:send-money
npm run smoke:failed-transaction
npm run smoke:notifications
npm run smoke:auth-security
npm run smoke:auth-deep
npm run smoke:password-reset
npm run smoke:production-guards
```

`smoke:password-reset` exercises the local forgot-password/reset-password flow. In development, Auth Service returns the reset token so the test can run without email infrastructure. Production must use email delivery instead of returning reset tokens to the browser.

`./scripts/docker-storage-check.sh` reports Docker storage usage, SwiftPay container logging policy, and the largest visible Docker `json-file` logs. Run it before demos or during disk-pressure incidents so oversized logs are caught early.

## k3s dev operator path

This is the current owned local Kubernetes path for the workspace.

```bash
./scripts/k8s-dev-deploy.sh
./scripts/k8s-dev-verify.sh
./scripts/k8s-dev-destroy.sh
./scripts/k8s-backup-run.sh
./scripts/k8s-backup-inspect.sh
./scripts/k8s-backup-delete.sh --help
./scripts/k8s-restore-run.sh
./scripts/k8s-restore-verify.sh
```

Use this when you want SwiftPay running on the shared local `k3s` runtime with Traefik, not the older MicroK8s learner track.

See [k3s dev deployment](../docs/k3s-dev-deployment.md).

See [Kubernetes backup and restore](../docs/K8S_BACKUP_RESTORE.md).

### `smoke-dev.sh`
**Public dev edge smoke check** for the active SwiftPay runtime.

```bash
# Usage
./scripts/smoke-dev.sh
```

**Features:**
- verifies the `swiftpay-dev` Argo CD application is present
- prints current `swiftpay-dev` pod state
- probes `https://swiftpay.eseosadevbox.com/`
- probes `https://swiftpay.eseosadevbox.com/api/health`
- provides a read-only check that the live public `dev` edge is reachable

### `k8s-backup-run.sh`
**SwiftPay state backup runner** for the owned `k3s` path.

```bash
# Usage
./scripts/k8s-backup-run.sh
```

**Features:**
- creates a one-off backup job from the scheduled SwiftPay state backup CronJob
- streams PostgreSQL and Redis backup container logs

### `k8s-backup-inspect.sh`
**Backup artifact inspector** for the SwiftPay backup PVC.

```bash
# Usage
./scripts/k8s-backup-inspect.sh
```

**Features:**
- mounts `swiftpay-backup-storage`
- lists retained PostgreSQL dump and Redis snapshot artifacts

### `k8s-backup-delete.sh`
**Backup artifact cleanup helper** for the SwiftPay backup PVC.

```bash
# Delete all backup artifacts
./scripts/k8s-backup-delete.sh --all

# Keep only the newest PostgreSQL dump and newest Redis snapshot
./scripts/k8s-backup-delete.sh --keep-latest
```

**Features:**
- deletes all backup artifacts when requested
- prunes older backup artifacts while keeping the newest backup set
- mounts `swiftpay-backup-storage` directly so cleanup is reliable on local `k3s`

### `k8s-restore-run.sh`
**SwiftPay state restore runner** for the owned `k3s` path.

```bash
# Usage
./scripts/k8s-restore-run.sh

# Restore a specific backup set
./scripts/k8s-restore-run.sh swiftpay-postgres-YYYYMMDDTHHMMSSZ.dump swiftpay-redis-YYYYMMDDTHHMMSSZ.rdb
```

**Features:**
- scales the SwiftPay service deployments, RabbitMQ, and Redis down before restore
- restores PostgreSQL-backed business data
- restores Redis continuity state
- scales workloads back up after restore

Before using this against a live ArgoCD-managed `swiftpay-dev` namespace, suspend automated sync on both:

- `internal-developer-platform-dev-root`
- `swiftpay-dev`

### `k8s-restore-verify.sh`
**Restore verification runner** for the owned `k3s` path.

```bash
# Usage
./scripts/k8s-restore-verify.sh
```

**Features:**
- confirms the main SwiftPay workloads are ready again
- waits for PostgreSQL to accept connections before running SQL validation
- verifies PostgreSQL business tables exist and are queryable
- verifies Redis PVC state files exist on the restored volume

## deploy-microk8s.sh (recommended for local / beginners)

One script to run SwiftPay on MicroK8s: **clone repo → run script**. It will:

- Install MicroK8s if you don’t have it (macOS: VM with 6 CPU, 12 GB RAM by default; Linux: snap).
- Start the VM if it was stopped, enable addons, deploy the app, and wait for DB migration.
- Print how to access the app (port-forward or ingress).

**Usage:**

```bash
./scripts/deploy-microk8s.sh
```

**Requirements:** Docker (and on macOS, Multipass). Optional: set `MICROK8S_VM_CPU` and `MICROK8S_VM_MEM_GB` before running to size the VM (e.g. `MICROK8S_VM_CPU=8 MICROK8S_VM_MEM_GB=16 ./scripts/deploy-microk8s.sh`).

See [MicroK8s deployment guide](../docs/microk8s-deployment.md#quick-start-one-script-deploy).

**Optional — add a worker later (macOS Multipass only):**

```bash
./scripts/deploy-microk8s.sh add-worker [VM_NAME] [CPUS] [MEM_GB] [DISK_GB]
# VM_NAME defaults to the next free swiftpay-worker-N (2 CPU, 4G RAM, 20G disk if omitted)
```

**Tear down workers + SwiftPay namespace** (e.g. before a clean re-deploy):

```bash
./scripts/deploy-microk8s.sh remove-workers
```

---

## setup-hosts-swiftpay-local.sh

Add `www.swiftpay.local` and `api.swiftpay.local` to `/etc/hosts` so you can use the local Ingress without port-forwarding. Run once on your Mac after deploying with the local overlay. See [Access Application](../docs/microk8s-deployment.md#method-2-ingress-with-swiftpaylocal-no-port-forward-local-overlay-only).

```bash
./scripts/setup-hosts-swiftpay-local.sh
```

## fix-microk8s-nodes.sh

Start stopped Multipass worker VMs so NotReady nodes become Ready again. See [MicroK8s deployment doc](../docs/microk8s-deployment.md#pods-stuck-pending--notready-nodes-multipass-workers).

---

## build-push-ecr.sh

Build all service images and push to ECR with a single tag (e.g. v5). Use after code changes so the cluster runs the new code.

**Usage:**

```bash
./scripts/build-push-ecr.sh [IMAGE_TAG]
# Default tag: v5
./scripts/build-push-ecr.sh v5
```

**Requirements:** AWS CLI configured, Docker, and ECR repos created (Terraform EKS module creates these).

**Then deploy:**

```bash
cd k8s/overlays/eks
IMAGE_TAG=v5 ./deploy.sh
```

## Terraform (RDS / Redis access)

If pods cannot reach RDS or Redis, add the EKS node security group IDs to Terraform so both RDS and ElastiCache allow traffic:

1. Get EKS node SGs (from AWS console or `aws ec2 describe-security-groups` for the EKS VPC).
2. In `terraform/aws/managed-services/terraform.tfvars` set:
   ```hcl
   additional_rds_security_group_ids = ["sg-xxx", "sg-yyy"]
   ```
3. Run `terraform apply` in `terraform/aws/managed-services`.

The same list is used for RDS (5432) and Redis (6379).
