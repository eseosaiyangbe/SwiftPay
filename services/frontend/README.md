# Frontend

**Served on:** port 80 (nginx) | **Build tool:** React + Vite/CRA | **Runtime:** nginx

## What this service owns

A single-page React application served by nginx. It owns no data — everything comes from the API Gateway via `/api/*` requests.

## Why nginx instead of just serving the React build directly?

Two reasons:

1. **Proxy** — the browser sends `/api/wallets` and nginx rewrites it to `http://api-gateway.payflow.svc.cluster.local:80/api/wallets`. Without this proxy, the browser would need to know the API Gateway's address directly — which changes between environments (localhost, MicroK8s, EKS, AKS). With nginx, the frontend always talks to itself and nginx handles the routing.

   > **What's `.svc.cluster.local`?** It's Kubernetes's internal DNS suffix. `api-gateway.payflow.svc.cluster.local` means "the Service named `api-gateway` in the `payflow` namespace." It only resolves inside the cluster — your browser can't use it, but nginx running inside a pod can.

2. **SPA routing** — React apps handle routing in JavaScript. If you reload `http://www.payflow.local/dashboard`, nginx must serve `index.html` (not 404), and React's router takes over. The `try_files $uri $uri/ /index.html;` line in nginx.conf handles this.

## Key files

| File | Purpose |
|------|---------|
| `nginx.conf.template` | nginx config with `${API_GATEWAY_URL}` and `${NGINX_RESOLVER}` placeholders substituted at container startup |
| `nginx.conf` | Static reference copy (not used at runtime) |
| `docker-entrypoint.sh` | Runs `envsubst` (substitutes `${VARIABLE}` placeholders in a file) to produce the final nginx config, then starts nginx |
| `Dockerfile` | Multi-stage: Node builds React → nginx serves the static files |

## How environment variables work

Unlike Node.js services that read `process.env` at runtime, React bakes env vars into the JavaScript bundle **at build time**. For things that need to change between environments (the API URL), this service uses nginx's proxy instead — the React code always calls `/api/...` and nginx proxies to wherever the API Gateway actually is.

The only runtime env vars are nginx config values set in `docker-entrypoint.sh`:

| Variable | Local MicroK8s | Docker Compose |
|----------|---------------|----------------|
| `API_GATEWAY_URL` | `http://api-gateway.payflow.svc.cluster.local:80` | `http://api-gateway:3000` |
| `NGINX_RESOLVER` | `10.152.183.10` (kube-dns ClusterIP) | `127.0.0.11` |

> **Why must NGINX_RESOLVER be an IP?** When `proxy_pass` uses a variable (`$api_upstream`), nginx resolves the hostname at request time using this DNS server. nginx's `resolver` directive only accepts IP addresses — not hostnames. `10.152.183.10` is the kube-dns Service IP in MicroK8s; `127.0.0.11` is Docker's built-in DNS.

## Run it locally (Docker Compose)

```bash
cd ../..
docker compose up -d frontend
# Open http://localhost
```

## Build and inspect the nginx config

```bash
# Run from the repository root (not from inside services/frontend/)
docker build -t payflow-frontend ./services/frontend

# Check what nginx.conf.template produces after substitution
docker run --rm \
  -e API_GATEWAY_URL=http://api-gateway:3000 \
  -e NGINX_RESOLVER=127.0.0.11 \
  payflow-frontend \
  cat /etc/nginx/conf.d/default.conf
```

## Common issue: nginx CrashLoopBackOff in Kubernetes

If you see:
```
host not found in upstream "api-gateway..." in .../default.conf
```

The `NGINX_RESOLVER` is wrong or missing. nginx needs a **DNS server IP** to resolve `$api_upstream` at request time. For MicroK8s:
```bash
kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}'
# 10.152.183.10 — use this as NGINX_RESOLVER
```

See also: [`TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) → "Frontend returns 502 for all /api/* requests".

---

**You've read all 6 services. Read next:**
- [`docs/system-flow.md`](../../docs/system-flow.md) — now trace a full money transfer end-to-end with everything you know
- [`docs/microk8s-deployment.md`](../../docs/microk8s-deployment.md) — deploy the whole system to Kubernetes
- [`LEARNING-PATH.md`](../../LEARNING-PATH.md) — pick up where you are in the week-by-week guide
