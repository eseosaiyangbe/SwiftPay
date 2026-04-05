# Home lab drills

Hands-on exercises you run on your own machine. Each drill practices **one** skill: reading symptoms, using the right commands, and connecting cause to fix.

**Learning path:** These drills match **Week 2** of [`LEARNING-PATH.md`](../LEARNING-PATH.md). Week 1 is **MicroK8s-first**; drills that say “Docker Compose” are for the optional Compose path or for mixed practice.

**Before you start:** App healthy?

- **MicroK8s (default path):** `./scripts/validate.sh --env k8s --host http://api.payflow.local`
- **Docker Compose (optional Week 1 shortcut):** `./scripts/validate.sh`

**After each drill:** Write one line in a notebook or `LAB-NOTES.md`:

`symptom → command that proved it → root cause`

---

## Drill 0 — Baseline (5 min)

**Goal:** Know what “healthy” looks like so you can spot regressions.

**Do:**

1. Open the UI, log in, confirm dashboard loads.
2. `kubectl get pods -n payflow` (MicroK8s) — all app pods `Running` / jobs `Completed`.
3. Pick any backend pod: `kubectl logs -n payflow deploy/transaction-service --tail=5` — no repeating errors.

**Note:** `transaction-timeout-handler-*` pods showing `Completed` is normal (CronJob).

**Read next:** Pick any drill below.

---

## Drill 1 — Trace one click (15 min)

**Goal:** Tie UI → API → logs.

**Do:**

1. Open two browsers (or profiles), two users, send a small amount.
2. In DevTools → Network, find `POST .../transactions` — copy response `id` or note time.
3. `kubectl logs -n payflow deploy/transaction-service --tail=50 | grep -i correlation`
4. Find the same request by timestamp or transaction id in the log line.

**Expected:** You see `correlationId` (or equivalent) in transaction-service logs.

**Why it matters:** Production debugging always starts with “one request ID across services.”

---

## Drill 2 — Kubernetes self-heal (10 min)

**Goal:** Deployments replace deleted pods.

**Setup:** MicroK8s, `payflow` namespace applied.

**Do:**

```bash
kubectl get pods -n payflow -l app=transaction-service
kubectl delete pod -n payflow -l app=transaction-service   # deletes one pod
kubectl get pods -n payflow -l app=transaction-service -w  # new pod appears
```

**Expected:** New pod name, `Running` within ~30–90s.

**If stuck:** `kubectl describe pod -n payflow <name>` → Events (ImagePull, quota, etc.).

**Read next:** [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) → MicroK8s section.

---

## Drill 3 — Scale to zero and back (10 min)

**Goal:** See how traffic behaves when a tier is gone.

**Do:**

```bash
kubectl scale deployment/frontend -n payflow --replicas=0
# Browser: site should fail or not load
kubectl scale deployment/frontend -n payflow --replicas=1
kubectl rollout status deployment/frontend -n payflow
```

**Expected:** Brief outage, then recovery.

**Why it matters:** Rolling updates and incidents use the same primitives (`scale`, `rollout`).

---

## Drill 4 — Events are the truth (10 min)

**Goal:** Use `kubectl get events` before guessing.

**Do:**

```bash
kubectl get events -n payflow --sort-by='.lastTimestamp' | tail -30
```

Then repeat Drill 2 and watch new events appear.

**Expected:** You see `Scheduled`, `Pulling`, `Started`, or errors with clear messages.

---

## Drill 5 — Wrong `/etc/hosts` IP (MicroK8s, 10 min)

**Goal:** Diagnose “browser can’t reach app” when the cluster is fine.

**Setup:** You use `www.payflow.local` / `api.payflow.local` via ingress.

**Do:**

1. Run `multipass list | grep microk8s-vm` — note the **current** IPv4.
2. Deliberately set `/etc/hosts` to a **wrong** IP for `www.payflow.local`.
3. Try `curl -s -o /dev/null -w "%{http_code}\n" http://www.payflow.local` — often `000` or timeout.
4. Fix: `./scripts/setup-hosts-payflow-local.sh` (updates hosts from live Multipass IP) or edit `/etc/hosts` manually.

**Expected:** After fix, `curl` returns `200` (or `301`/`302`).

**Read next:** [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) → Ingress / hosts sections; [`microk8s-deployment.md`](microk8s-deployment.md).

---

## Drill 6 — RabbitMQ down (Docker Compose, 15 min)

**Goal:** Map “message queue unavailable” to infrastructure.

**Setup:** Stack running via `docker compose`.

**Do:**

```bash
docker compose stop rabbitmq
# In UI: try Send Money — expect failure mentioning queue / unavailable
docker compose start rabbitmq
# Wait ~30s for RabbitMQ “Server startup complete” in logs
docker compose logs rabbitmq --tail=20
```

**Expected:** Failure while stopped; success after RabbitMQ is up.

**On Kubernetes:** If policies block AMQP port `5672`, you get a similar user-facing error; see [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) → “Message queue unavailable”.

---

## Drill 7 — Insufficient CPU (Kubernetes, 10 min)

**Goal:** Read `Pending` + Events for resource pressure.

**Do:** Same commands as in [`LEARNING-PATH.md`](../LEARNING-PATH.md) Week 2 → “Try starving resources” (patch `api-gateway` to request `cpu: "99"`, observe `Pending`, then `kubectl rollout undo`).

**Expected:** Event text includes `Insufficient cpu` (or memory if you used memory instead).

---

## Drill 8 — Postgres data survives restart (Docker Compose, 15 min)

**Goal:** Data is not “in the container image.”

**Do:**

1. Note your balance or a transaction id in the UI.
2. `docker compose restart postgres`
3. Wait for health, refresh UI — same user, same history.

**Expected:** Data still there (volume-backed).

**Stretch:** `docker compose down` vs `docker compose down -v` — **only** use `-v` if you accept wiping local DB.

---

## Drill 9 — `validate.sh` as smoke test (5 min)

**Goal:** Automate “is the stack up?”

**Do:**

```bash
./scripts/validate.sh
# MicroK8s + ingress:
./scripts/validate.sh --env k8s --host http://api.payflow.local
```

**Expected:** `All checks passed` (wording may vary slightly).

**Why it matters:** CI and on-call use the same idea: one command that fails fast.

---

## Safety

- Run destructive commands **only** in your lab namespace (`payflow`) and repo you own.
- After drills that change manifests or scale, **undo** (rollout undo, scale back, fix hosts) so the next session starts clean.
- Do **not** commit real passwords or production kubeconfigs into the repo.

---

## Where to go after

| You want… | Open |
|-----------|------|
| Symptom → fix cheat sheet | [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) |
| Longer debugging narrative | [`troubleshooting.md`](troubleshooting.md) |
| Week-by-week structure | [`LEARNING-PATH.md`](../LEARNING-PATH.md) |
| Deploy local K8s | [`microk8s-deployment.md`](microk8s-deployment.md) |
| Public HTTPS URL for your lab (optional) | [`cloudflare-setup.md`](cloudflare-setup.md) |
