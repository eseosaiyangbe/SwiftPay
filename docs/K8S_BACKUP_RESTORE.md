# SwiftPay Kubernetes Backup And Restore

This document defines the owned backup and restore contract for the `swiftpay-dev` Kubernetes slice.

## Scope

The current SwiftPay Kubernetes backup and restore contract covers:

- PostgreSQL business data
  - users
  - wallets
  - transactions
  - notifications
  - refresh tokens
  - user sessions
- Redis continuity state
  - sessions
  - idempotency keys
  - cached balance and wallet entries

The contract does not currently include RabbitMQ queue state.

Why that exclusion is explicit:

- the current `swiftpay-dev` RabbitMQ deployment does not persist queue state on a PVC
- this means RabbitMQ remains an operationally useful but transient message surface in the local `dev` slice
- Phase 8 for SwiftPay therefore protects authoritative business data and Redis continuity state first

## Storage Model

Backups are stored on:

- PVC: `swiftpay-backup-storage`

Scheduled state backups are produced by:

- CronJob: `swiftpay-state-backup`

Default scheduled behavior:

- daily backup run at `0 2 * * *`
- keep the most recent `7` days by file age

Each backup run produces:

- `swiftpay-postgres-<timestamp>.dump`
- `swiftpay-redis-<timestamp>.rdb`

## Operator Commands

Run from the `SwiftPay` repo root.

Create a one-off backup:

```bash
./scripts/k8s-backup-run.sh
```

Inspect stored backups:

```bash
./scripts/k8s-backup-inspect.sh
```

Delete all stored backups:

```bash
./scripts/k8s-backup-delete.sh --all
```

Delete older backups but keep the newest PostgreSQL dump and newest Redis snapshot:

```bash
./scripts/k8s-backup-delete.sh --keep-latest
```

Restore the latest backup set:

```bash
./scripts/k8s-restore-run.sh
```

Restore a specific backup set:

```bash
./scripts/k8s-restore-run.sh swiftpay-postgres-YYYYMMDDTHHMMSSZ.dump swiftpay-redis-YYYYMMDDTHHMMSSZ.rdb
```

Verify restore state:

```bash
./scripts/k8s-restore-verify.sh
```

## GitOps Control During Restore Drills

Because `swiftpay-dev` is ArgoCD-managed, a live restore drill must temporarily suspend automated sync before scaling workloads down.

Suspend automation:

```bash
kubectl patch application internal-developer-platform-dev-root -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl patch application swiftpay-dev -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl get application internal-developer-platform-dev-root swiftpay-dev -n argocd -o wide
```

Re-enable automation after the drill:

```bash
kubectl patch application internal-developer-platform-dev-root -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application swiftpay-dev -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
kubectl annotate application swiftpay-dev -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl get application internal-developer-platform-dev-root swiftpay-dev -n argocd -o wide
```

## Restore Behavior

The restore path is intentionally sequenced.

Before restore:

- scale `api-gateway` to `0`
- scale `auth-service` to `0`
- scale `frontend` to `0`
- scale `notification-service` to `0`
- scale `transaction-service` to `0`
- scale `wallet-service` to `0`
- scale `rabbitmq` to `0`
- scale `redis` to `0`

During restore:

- restore PostgreSQL data from the selected `.dump`
- restore Redis state from the selected `.rdb`

After restore:

- scale `redis` back to its prior replica count
- scale `rabbitmq` back to its prior replica count
- scale the SwiftPay service deployments back to their prior replica counts
- wait for these workloads to become ready again

This sequencing is deliberate.

SwiftPay restore must not compete with active writers or queue consumers if we want a defensible recovery story.

## Verification Standard

A restore is not complete because the restore pod succeeded.

A restore is complete only when:

- PostgreSQL content is queryable again
- representative business tables exist
- representative row counts are queryable again
- Redis PVC state is present again
- `postgres`, `redis`, `rabbitmq`, and the main SwiftPay services are ready again

Use:

```bash
./scripts/k8s-restore-verify.sh
```

## Useful Live Commands

Check ArgoCD state for the app:

```bash
kubectl get application swiftpay-dev -n argocd -o wide
```

Check backup resources directly:

```bash
kubectl get cronjob,pvc -n swiftpay-dev | rg 'swiftpay-state-backup|swiftpay-backup-storage|NAME'
```

Check live runtime state:

```bash
kubectl get pods,pvc -n swiftpay-dev
```

Inspect recent namespace events:

```bash
kubectl get events -n swiftpay-dev --sort-by=.lastTimestamp | tail -n 30
```

## Pre-Restore Sanity Checks

Before you run a restore, do these checks:

1. confirm the app is currently `Synced` and `Healthy`

```bash
kubectl get application swiftpay-dev -n argocd -o wide
```

2. confirm the backup files you plan to use exist and are non-zero

```bash
./scripts/k8s-backup-inspect.sh
```

3. confirm the SwiftPay workloads are currently stable enough to scale down safely

```bash
kubectl get pods -n swiftpay-dev
```

4. if you are targeting a named backup set, record the exact filenames first

```bash
./scripts/k8s-restore-run.sh swiftpay-postgres-YYYYMMDDTHHMMSSZ.dump swiftpay-redis-YYYYMMDDTHHMMSSZ.rdb
```

5. suspend ArgoCD automated sync for the drill window

```bash
kubectl patch application internal-developer-platform-dev-root -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl patch application swiftpay-dev -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

## End-To-End Backup Flow

```bash
cd /Users/raymond/Documents/DevOps-Easy-Learning/SwiftPay
./scripts/k8s-backup-run.sh
./scripts/k8s-backup-inspect.sh
kubectl get cronjob,pvc -n swiftpay-dev | rg 'swiftpay-state-backup|swiftpay-backup-storage|NAME'
kubectl get application swiftpay-dev -n argocd -o wide
```

## End-To-End Restore Flow

```bash
cd /Users/raymond/Documents/DevOps-Easy-Learning/SwiftPay
kubectl get application swiftpay-dev -n argocd -o wide
kubectl get application internal-developer-platform-dev-root swiftpay-dev -n argocd -o wide
kubectl get pods -n swiftpay-dev
./scripts/k8s-backup-inspect.sh
kubectl patch application internal-developer-platform-dev-root -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl patch application swiftpay-dev -n argocd --type json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
./scripts/k8s-restore-run.sh swiftpay-postgres-YYYYMMDDTHHMMSSZ.dump swiftpay-redis-YYYYMMDDTHHMMSSZ.rdb
./scripts/k8s-restore-verify.sh
kubectl patch application internal-developer-platform-dev-root -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application swiftpay-dev -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
kubectl annotate application swiftpay-dev -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl get application internal-developer-platform-dev-root swiftpay-dev -n argocd -o wide
kubectl get application swiftpay-dev -n argocd -o wide
kubectl get pods -n swiftpay-dev
kubectl get events -n swiftpay-dev --sort-by=.lastTimestamp | tail -n 30
```

## Validated Restore Drill

The first controlled restore drill for `swiftpay-dev` completed successfully on `2026-05-23`.

Validated backup pair:

- `swiftpay-postgres-20260523T214822Z.dump`
- `swiftpay-redis-20260523T214822Z.rdb`

Validated restore results:

- PostgreSQL restore completed successfully from the selected `.dump`
- Redis continuity state was restored onto the Redis PVC
- verification confirmed these PostgreSQL tables:
  - `notifications`
  - `refresh_tokens`
  - `transactions`
  - `user_sessions`
  - `users`
  - `wallets`
- verification confirmed these representative row counts:
  - `users=1`
  - `wallets=1`
  - `transactions=0`
- verification confirmed Redis data files were present again:
  - `/redis-data/dump.rdb`
  - `/redis-data/appendonlydir/appendonly.aof.1.base.rdb`
  - `/redis-data/appendonlydir/appendonly.aof.1.incr.aof`
  - `/redis-data/appendonlydir/appendonly.aof.manifest`
- `swiftpay-dev` returned to `Synced` and `Healthy` after automation was restored

## Operational Lessons From The Drill

- namespace quota enforcement requires explicit CPU and memory requests and limits on backup, inspect, delete, restore, and verify helper pods
- macOS default Bash is `3.2`, so operator scripts must not rely on associative arrays
- restore verification must wait on PostgreSQL readiness explicitly; deployment or StatefulSet rollout status alone is not sufficient
- a live ArgoCD-managed restore drill must suspend automated sync on both the root app and `swiftpay-dev`

## Phase 8 Position

This is the second concrete implementation of the Phase 8 backup and restore standard in the workspace.

Implementation order now stands at:

1. `OpenSIS` reference pattern
2. `observability-stack` control-plane contract
3. `SwiftPay`
4. `FoodPulse`
5. `MemFlip`

## Image Rebuild Note

No custom image rebuild is required for this backup and restore slice.

This implementation uses:

- Kubernetes manifests
- repo-local operator scripts
- stock `postgres:16-alpine`, `redis:7-alpine`, and `busybox:1.36` runtime images
