# Cloudflare setup (optional — expose your home lab safely)

This guide is for learners who already run SwiftPay locally (**MicroK8s** or optional **Docker Compose**—see [`LEARNING-PATH.md`](../LEARNING-PATH.md)) and want a **real HTTPS URL** on the public internet without opening inbound ports on your home router the traditional way.

**What Cloudflare gives you:**

- **DNS** for a domain you own (or a subdomain).
- **Cloudflare Tunnel (`cloudflared`)** — outbound-only connection from your PC to Cloudflare; traffic to `https://app.yourdomain.com` is forwarded to `http://localhost` or your ingress VM. No need to expose port 80/443 on your WAN IP for the tunnel model.
- **SSL/TLS** termination at the edge (browser ↔ Cloudflare is always HTTPS).

**What this doc does *not* do:** replace Kubernetes ingress or SwiftPay’s own TLS story in production (EKS/ALB, cert-manager, etc.). This is a **home lab / demo** path.

---

## Prerequisites

1. A **Cloudflare account** (free tier is enough for tunnels and basic DNS).
2. A **domain** whose DNS is managed by Cloudflare (transfer the domain or change nameservers at your registrar to the pair Cloudflare shows you).
3. SwiftPay reachable on your machine:
   - **MicroK8s + Multipass:** `http://www.swiftpay.local` (with `/etc/hosts` from `scripts/setup-hosts-swiftpay-local.sh`). For Cloudflare Tunnel you need a **reachable IP:port** on the host—often `kubectl port-forward` the ingress controller to `127.0.0.1:8080` and tunnel to that, or hit the Multipass VM IP where ingress listens (see [`docs/microk8s-deployment.md`](microk8s-deployment.md)).
   - **Docker Compose (optional):** `http://localhost` (port 80)—easiest tunnel target if you are on the Compose path from [`LEARNING-PATH.md`](../LEARNING-PATH.md).

---

## Part 1 — SSL/TLS mode (read this before going live)

In Cloudflare Dashboard → **SSL/TLS** → **Overview**:

| Mode | When to use with SwiftPay |
|------|---------------------------|
| **Flexible** | Origin (your laptop) speaks **HTTP only**. Cloudflare talks HTTPS to browsers. Easiest for quick tests; **not** ideal for production (traffic Cloudflare → you is unencrypted). |
| **Full** | Origin uses **HTTPS** with a certificate (even a self-signed one, if you enable “Full” not “Full (strict)”). Use if you terminate TLS locally. |
| **Full (strict)** | Origin must present a **valid** cert for your hostname (e.g. Let’s Encrypt). Best practice when you have real certs on the origin. |

For a typical **tunnel → `http://127.0.0.1:80`** setup, start with **Flexible** or use **Full** only after you serve HTTPS locally.

---

## Part 2 — Cloudflare Tunnel (recommended for home lab)

### 1. Install `cloudflared`

- **macOS:** `brew install cloudflared`
- **Linux:** see [Cloudflare docs — Install cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)

### 2. Authenticate (one-time)

```bash
cloudflared tunnel login
```

This opens a browser window and downloads a **cert.pem** into your user config. That file is **secret** — it is already covered by `.gitignore` patterns such as `*.pem` and `.cloudflared/`. **Never commit it.**

### 3. Create a tunnel

```bash
cloudflared tunnel create swiftpay-lab
```

Note the **Tunnel ID** printed. Cloudflare also creates a **credentials JSON** file under `~/.cloudflared/` — **never commit** that file (repo ignores `.cloudflared/`).

### 4. Configure the tunnel

Create **`~/.cloudflared/config.yml`** (outside the repo, or symlink — do not paste tokens into the Git repo):

```yaml
tunnel: <TUNNEL_ID_FROM_STEP_3>
credentials-file: /Users/YOU/.cloudflared/<TUNNEL_ID>.json

ingress:
  # Public hostname → local service (Docker Compose frontend on port 80)
  - hostname: app.yourdomain.com
    service: http://127.0.0.1:80
  # Optional: API on another hostname if your gateway is exposed separately
  - hostname: api.yourdomain.com
    service: http://127.0.0.1:3000
  # Catch-all required
  - service: http_status:404
```

Adjust ports to match your machine:

- Frontend nginx on **80** → `http://127.0.0.1:80`
- API gateway only on **3000** → `http://127.0.0.1:3000`

If the React app expects `/api` on the **same host** as the UI, prefer **one** hostname tunneling to **port 80** (Compose) so nginx can proxy `/api` like in production.

### 5. Route DNS to the tunnel

In Cloudflare Dashboard → **Zero Trust** → **Networks** → **Tunnels** → your tunnel → **Public hostname** → add `app.yourdomain.com` → same service as in `config.yml`.

Or CLI:

```bash
cloudflared tunnel route dns swiftpay-lab app.yourdomain.com
```

### 6. Run the tunnel

```bash
cloudflared tunnel run swiftpay-lab
```

For a persistent service, use **launchd** (macOS), **systemd** (Linux), or Cloudflare’s documented service install.

### 7. SwiftPay-specific notes

- **CORS / API URL:** If the browser loads `https://app.yourdomain.com` but the SPA was built to call `http://localhost:3000/api`, calls will fail. Prefer the **relative** `/api` path through nginx (default Docker build) so one hostname works.
- **Cookies / JWT:** Same-site and secure cookie flags may differ over HTTPS; if login breaks, check browser devtools → Network and compare to local HTTP.
- **Ingress hostnames:** Kubernetes manifests may still say `www.swiftpay.local`. For tunneling to localhost Compose, you don’t change K8s. For tunneling **directly** to an in-cluster ingress, you must add your real domain to the Ingress **rules** and TLS blocks (advanced; separate from this quickstart).

---

## Part 3 — DNS only (no tunnel): A record to your home IP

Use only if you **want** to forward ports 80/443 from your router to one machine.

1. Cloudflare DNS → **A** record: `app` → your home **public** IPv4 (update when ISP changes, or use a dynamic DNS updater).
2. Router: port-forward **80** and **443** to the machine running Docker or the Multipass VM (complex on MicroK8s).
3. SSL/TLS: start with **Flexible** if origin is HTTP, or obtain certs on the origin for **Full (strict)**.

**Downside:** exposes your home IP and open ports; tunnel is usually simpler and safer for learning.

---

## Security checklist (home lab)

- [ ] No `.env`, `*.tfvars`, `kubeconfig`, or `.cloudflared/*.json` committed — see [`.gitignore`](../.gitignore).
- [ ] Turn on **Cloudflare WAF** (basic rules) on a paid plan if you expose real credentials; on free tier, use **strong unique passwords** and **rotate** after demos.
- [ ] Do not use production **RDS/Stripe/Twilio** keys on a tunnel URL shared publicly.
- [ ] After the lab, **delete** the tunnel or remove DNS records if you no longer need public access.

---

## Troubleshooting

| Symptom | Likely cause | What to try |
|--------|----------------|------------|
| `502 Bad Gateway` from Cloudflare | Tunnel running but wrong `service:` URL/port | `curl -v http://127.0.0.1:80` locally; fix `config.yml` |
| `525` / SSL handshake failed | SSL mode **Full** but origin is HTTP only | Set SSL to **Flexible** or serve HTTPS on origin |
| App loads, API `CORS` or `404` | Split hostnames vs single nginx proxy | Single hostname → port 80 with `/api` proxy |
| Tunnel disconnects | Laptop sleep, unstable network | Run tunnel on a small always-on host (Raspberry Pi, etc.) |

**SwiftPay docs:** [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) for application-level issues (DB, RabbitMQ, ingress).

---

## Read next

- [`microk8s-deployment.md`](microk8s-deployment.md) — local Kubernetes and ingress
- [`HOME-LAB-DRILLS.md`](HOME-LAB-DRILLS.md) — practice breaking and fixing the stack
- [`understanding-ingress.md`](understanding-ingress.md) — how Ingress maps hostnames to services
