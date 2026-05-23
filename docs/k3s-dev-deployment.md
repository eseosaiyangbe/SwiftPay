# SwiftPay k3s Dev Deployment

This is the owned Phase 7 Kubernetes path for SwiftPay in the DevOps Easy Learning workspace.

It is intentionally different from the older MicroK8s learning path:

- it targets the shared local `k3s` runtime standard used across the workspace
- it uses Traefik as the ingress layer
- it deploys into `swiftpay-dev`
- it is sized for repeatable local validation on macOS and Linux

## What This Path Is For

Use this path when you want to validate SwiftPay as a real local Kubernetes workload in the same platform story as:

- `MemFlip` on `k3s`
- the shared control plane in `Obervability-Stack`
- the future Vault, ArgoCD, and Traefik platform direction

Use the older MicroK8s docs only if you are intentionally following the legacy learner workflow or maintaining that earlier environment.

For production intent, the owned overlay is now `k8s/overlays/prod`. It removes git-stored runtime secrets and assumes Vault is the source of truth, with External Secrets Operator materializing `db-secrets` inside `swiftpay-prod`.

The same Vault-backed model now applies to `swiftpay-dev` as well. The local k3s path no longer relies on a checked-in `db-secrets` manifest.

## Prerequisites

- Docker running
- `kubectl` installed
- local `k3s` runtime available
  - macOS: Colima with embedded `k3s`
  - Linux: native `k3s`
- Traefik available in the cluster

The shared workspace helper can bootstrap that runtime:

```bash
./scripts/ensure-k3s-runtime.sh
```

## Deploy

From the workspace root:

```bash
cd SwiftPay
./scripts/k8s-dev-deploy.sh
```

What the script does:

1. validates `k8s/overlays/dev`
2. builds local SwiftPay service images tagged as `*:dev`
3. applies the dev overlay into namespace `swiftpay-dev`
4. waits for infra, migration, and service rollouts
5. runs the verification path

Before validation, the script also bootstraps the shared Vault and External Secrets platform unless you pass `--skip-secrets-platform`.

## Lifecycle Controls

For the repo-local SwiftPay dev slice, use these commands deliberately:

### Start or resume the dev slice

```bash
cd SwiftPay
./scripts/k8s-start.sh
```

This script:

1. resumes the preserved `swiftpay-dev` workloads if the namespace already exists
2. falls back to the full deploy path only when the namespace does not exist
3. preserves PostgreSQL and Redis PVC-backed state across normal stop/start cycles
4. can still force a fresh image rollout with `--build`

### Stop the dev slice safely

```bash
cd SwiftPay
./scripts/k8s-stop.sh
```

This script:

1. scales the SwiftPay deployments down to `0`
2. scales the PostgreSQL statefulset down to `0`
3. preserves the namespace and PVC-backed state
4. does not intentionally remove SwiftPay runtime data

If you want it to wait for workloads to terminate:

```bash
cd SwiftPay
./scripts/k8s-stop.sh --wait
```

### Destructive reset for a clean reinstall

```bash
cd SwiftPay
./scripts/k8s-reset.sh --wait
```

This script:

1. deletes the entire `swiftpay-dev` namespace
2. removes the PostgreSQL and Redis PVC-backed state
3. destroys the current SwiftPay dev runtime data
4. leaves the next `./scripts/k8s-start.sh` run to recreate the namespace and full deploy path

For unattended reset runs:

```bash
cd SwiftPay
./scripts/k8s-reset.sh --yes --wait
```

## Verify

```bash
cd SwiftPay
./scripts/k8s-dev-verify.sh
```

The verification path checks:

- Kubernetes objects in `swiftpay-dev`
- Traefik ingress routing
- API gateway health
- end-to-end auth and wallet flow via `./scripts/validate.sh`
- PostgreSQL, Redis, and RabbitMQ health

## Backup And Restore

The owned `swiftpay-dev` Kubernetes path now has an explicit backup and restore contract.

Coverage:

- PostgreSQL business data
- Redis continuity state

Primary reference:

- [K8S_BACKUP_RESTORE.md](/Users/raymond/Documents/DevOps-Easy-Learning/SwiftPay/docs/K8S_BACKUP_RESTORE.md)

Fast operator checks:

```bash
kubectl get application swiftpay-dev -n argocd -o wide
kubectl get cronjob,pvc -n swiftpay-dev | rg 'swiftpay-state-backup|swiftpay-backup-storage|NAME'
./scripts/k8s-backup-run.sh
./scripts/k8s-backup-inspect.sh
./scripts/k8s-backup-delete.sh --keep-latest
./scripts/k8s-restore-run.sh swiftpay-postgres-YYYYMMDDTHHMMSSZ.dump swiftpay-redis-YYYYMMDDTHHMMSSZ.rdb
./scripts/k8s-restore-verify.sh
```

For a live restore drill under ArgoCD, suspend automated sync on `internal-developer-platform-dev-root` and `swiftpay-dev` before running `k8s-restore-run.sh`, then re-enable automation and hard-refresh `swiftpay-dev` after verification. The full end-to-end sequence is documented in [K8S_BACKUP_RESTORE.md](/Users/raymond/Documents/DevOps-Easy-Learning/SwiftPay/docs/K8S_BACKUP_RESTORE.md).

## Access

The overlay publishes these hosts through Traefik:

- `www.swiftpay.devops.local`
- `swiftpay.devops.local`
- `api.swiftpay.devops.local`

You can either:

- add them to `/etc/hosts` pointing at the Traefik ingress address
- or use `curl` with a `Host` header during operator checks

To discover the current Traefik address:

```bash
kubectl get svc traefik -n traefik
```

## Notes

- This dev path keeps local self-hosted PostgreSQL, Redis, and RabbitMQ for repeatability.
- It does not replace the cloud overlays under `k8s/overlays/eks` and `k8s/overlays/aks`.
- It does not replace the older MicroK8s learner content; it supersedes it as the owned Phase 7 local Kubernetes path.
