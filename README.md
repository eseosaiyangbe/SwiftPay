# SwiftPay Wallet

![SwiftPay Wallet](assets/logo.png)

> A production-grade fintech microservices platform for digital payments with multi-cloud Kubernetes deployment.

SwiftPay Wallet is a complete payment platform demonstrating real-world microservices architecture. It processes money transfers asynchronously, prevents duplicate charges through idempotency, and scales across AWS EKS and Azure AKS. Built with Node.js, PostgreSQL, Redis, and RabbitMQ—the same stack used by Stripe and Square.

> **New here?** Start with [`LEARNING-PATH.md`](LEARNING-PATH.md) (week-by-week). **Docs are indexed** in [`docs/README.md`](docs/README.md) so you can pick one path instead of every guide at once.

**Deep dive (design choices, fintech mindset, end-to-end traces):** [*Building SwiftPay* — a developer’s field guide](https://osomudeya.gumroad.com/l/swiftpay) walks through why the system is built the way it is (atomicity, idempotency, queues vs HTTP, Terraform/Kubernetes, security, observability, CI/CD). It complements this repo’s markdown docs; when something disagrees, **the repo and running code are the source of truth**.

**Credit:** If you use this repo as a base for your own project, course, or content, please **acknowledge SwiftPay Wallet** and link to [https://github.com/Ship-With-Zee/swiftpay-wallet](https://github.com/Ship-With-Zee/swiftpay-wallet). See [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution guidelines and attribution details.

## Architecture

```mermaid
graph TB
    Browser[Browser] -->|HTTP| Frontend[Frontend:80<br/>React + Nginx]
    Frontend -->|/api/*| Gateway[API Gateway:3000<br/>Express.js]
    
    Gateway -->|/api/auth/*| Auth[Auth Service:3004<br/>JWT + Redis Sessions]
    Gateway -->|/api/wallets/*| Wallet[Wallet Service:3001<br/>Balance Management]
    Gateway -->|/api/transactions/*| Transaction[Transaction Service:3002<br/>Async Processing]
    Gateway -->|/api/notifications/*| Notification[Notification Service:3003<br/>Email/SMS]
    
    Transaction -->|HTTP| Wallet
    Transaction -->|Publish| RabbitMQ[RabbitMQ:5672<br/>Message Queue]
    RabbitMQ -->|Consume| Notification
    
    Auth --> PostgreSQL[(PostgreSQL:5432<br/>Primary Database)]
    Wallet --> PostgreSQL
    Transaction --> PostgreSQL
    Notification --> PostgreSQL
    
    Auth --> Redis[(Redis:6379<br/>Sessions + Cache)]
    Wallet --> Redis
    Transaction --> Redis
    
    Gateway -.->|Deploy| EKS[AWS EKS]
    Gateway -.->|Deploy| AKS[Azure AKS]
```

*EKS hub-and-spoke pipeline (higher resolution and related figures: [docs/architecture.md](docs/architecture.md)).*

![EKS VPC integration pipeline](docs/assets/EKS%20VPC%20Integration%20Pipeline-2026-03-30-135753.png)

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Frontend** | React 18.2.0 | User interface |
| **Web Server** | Nginx | Static files + API proxy |
| **API Gateway** | Express.js 4.18.2 | Request routing, auth, rate limiting |
| **Auth Service** | Express.js 4.18.2 | JWT tokens, bcrypt, Redis sessions |
| **Wallet Service** | Express.js 4.18.2 | Balance management, atomic transfers |
| **Transaction Service** | Express.js 4.18.2 | Async processing, RabbitMQ, circuit breakers |
| **Notification Service** | Express.js 4.18.2 | Email (nodemailer), SMS (Twilio) |
| **Database** | PostgreSQL 15 | ACID transactions, relational data |
| **Cache** | Redis 7 | Sessions, idempotency keys, balance cache |
| **Message Queue** | RabbitMQ 3 | Async processing, retries, DLQ |
| **Containerization** | Docker | Service isolation |
| **Orchestration** | Kubernetes | EKS (AWS), AKS (Azure) |
| **Infrastructure** | Terraform | Multi-cloud provisioning |

## Golden Path — Pick Your Environment

**Phase 7 workspace standard:** use the `k3s` dev path first when you want SwiftPay to participate in the shared Kubernetes story with Traefik and the control plane. Keep the older MicroK8s path for legacy learner flow and repo history.

### ☸️ Environment 1: k3s Dev (10–20 minutes) — recommended for the current workspace

This is the owned Phase 7 local Kubernetes path for macOS and Linux. It aligns SwiftPay with the workspace `k3s` runtime, Traefik ingress, and the same migration pattern already proven with MemFlip.

From the repo root, run:

```bash
./scripts/ensure-k3s-runtime.sh
cd SwiftPay
./scripts/k8s-dev-deploy.sh
```

Primary docs: [`docs/k3s-dev-deployment.md`](docs/k3s-dev-deployment.md)

**What you get:**

- namespace: `swiftpay-dev`
- ingress hosts:
  - `www.swiftpay.devops.local`
  - `swiftpay.devops.local`
  - `api.swiftpay.devops.local`
- Traefik ingress
- local self-hosted Postgres, Redis, and RabbitMQ inside the cluster
- Vault-backed secret delivery for `swiftpay-dev`
- repeatable deploy, verify, and destroy scripts

For the production contract, use `k8s/overlays/prod`. That overlay drops local infra, assumes managed dependencies, and expects Vault-backed secret materialization through External Secrets Operator. The target namespace is `swiftpay-prod`.

**Verify:**

```bash
cd SwiftPay
./scripts/k8s-dev-verify.sh
```

**Teardown:**

```bash
cd SwiftPay
./scripts/k8s-dev-destroy.sh
```

---

### ☸️ Environment 2: MicroK8s (15–20 minutes) — legacy learner path

Production-like Kubernetes on your machine—the same shape as cloud, without AWS cost.

From the repo root, run **`./scripts/deploy-microk8s.sh`**. It installs or uses MicroK8s, enables addons (registry, ingress, etc.), optionally builds and loads images, applies `k8s/overlays/local`, and prints access hints. Requires **Docker**. **macOS:** **Multipass** too. **Linux:** snap-based MicroK8s on the host (single-node; workers not auto-provisioned). **Windows:** use **WSL2** + Linux — native Windows shells are not supported by this script. Details: [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md).

**After deploy:** add hosts, validate, open the app:

```bash
bash scripts/setup-hosts-swiftpay-local.sh   # 127.0.0.1  www.swiftpay.local api.swiftpay.local
export KUBECONFIG="${HOME}/.kube/microk8s-config"   # if deploy script printed this
./scripts/validate.sh --env k8s --host http://api.swiftpay.local
open http://www.swiftpay.local
```

**Manual MicroK8s:** `microk8s enable dns storage registry ingress metrics-server`, kubeconfig, then `kubectl apply -k k8s/overlays/local`—see [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md).

**Optional — GitOps on the laptop:** [`docs/cicd-local.md`](docs/cicd-local.md) (`.github/workflows/gitops-local.yml`).

**Teardown:**
```bash
kubectl delete namespace swiftpay
```

---

### 🐳 Environment 3: Docker Compose (~5 minutes) — optional, no Kubernetes

Fastest way to see the stack locally when you cannot or do not want MicroK8s yet. In Docker Compose, the browser entrypoint is **`http://localhost:8081`** and the API gateway health endpoint is **`http://localhost:3007/health`**.

```bash
git clone https://github.com/<your-username>/swiftpay-wallet-2.git && cd swiftpay-wallet-2
docker compose up -d
# Wait ~30 seconds for Postgres, then:
./scripts/docker-storage-check.sh
./scripts/validate.sh
open http://localhost:8081
# API: http://localhost:3007/health — RabbitMQ UI: http://localhost:15672 (swiftpay / swiftpay123)
```

**Monitoring profile** (Prometheus + Grafana + Alertmanager)—great for the learning path “minimal triad”:

```bash
docker compose --profile monitoring up -d
open http://localhost:3006      # Grafana (admin / admin)
open http://localhost:9090      # Prometheus
```

**Teardown:**
```bash
docker compose down -v
```

`./scripts/validate.sh` targets the API gateway in Docker Compose, not the frontend. Use it to verify service health and core API flows after startup.

For Docker-host health, `./scripts/docker-storage-check.sh` gives a fast operator view of Docker storage usage, SwiftPay logging policy, and the largest visible container log files. This is especially useful when several local projects share the same Docker runtime.

---

### ☁️ Environment 4: AWS EKS (first time ~45–90 minutes)

Full production deployment with RDS, ElastiCache, Amazon MQ.

**Prerequisites:** AWS CLI configured, Terraform ≥ 1.5, `kubectl`, `helm`.

**Infrastructure — pick one:**

- **Scripted:** From the repo root, run **`./spinup.sh`**, choose **aws** and your workspace (**dev** / **prod**). It bootstraps remote state (S3 + DynamoDB), then applies Hub VPC → EKS spoke → managed services → bastion → FinOps in order. When it prints *Spin-up complete*, continue with the steps below (bastion tunnel through deploy).
- **Manual Terraform:** run the module sequence yourself (same order as `spinup.sh`):

```bash
# 1. Bootstrap Terraform state (one-time)
cd terraform && ./bootstrap.sh --aws-only

# 2. Deploy infrastructure IN ORDER (order matters — see terraform/README.md)
cd aws/hub-vpc          && terraform init && terraform apply -auto-approve
cd ../spoke-vpc-eks     && terraform init && terraform apply -auto-approve
cd ../managed-services  && terraform init && terraform apply -auto-approve
cd ../bastion           && terraform init && terraform apply -auto-approve
```

**After infrastructure (both options):**

```bash
# 3. Open bastion tunnel so kubectl can reach the private EKS endpoint (from repo root)
BASTION_IP=$(terraform -chdir=terraform/aws/bastion output -raw bastion_public_ip)
EKS_ENDPOINT=$(aws eks describe-cluster --name swiftpay-eks-cluster --query 'cluster.endpoint' --output text | sed 's|https://||')
ssh -i ~/.ssh/swiftpay-bastion.pem -L 6443:${EKS_ENDPOINT}:443 ec2-user@${BASTION_IP} -N &

# 4. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name swiftpay-eks-cluster

# 5. Install External Secrets Operator (one-time)
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait

# 6. Build & push images to ECR via CI
# Push to main branch → GitHub Actions builds and pushes to ECR automatically.
# Get the image tag from the CI summary, then:

# 7. Deploy (from repo root)
IMAGE_TAG=<git-sha-from-ci> ./k8s/overlays/eks/deploy.sh

# 8. Validate
./scripts/validate.sh --env cloud --host https://$(kubectl get ingress -n swiftpay -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
```

`./spinup.sh` can also target **Azure (AKS)** if you choose `aks` at the prompt; use the AKS deploy path in the short form below when deploying the app.

---

## What You'll Learn

- **Why database transactions matter** — Atomic debit/credit in PostgreSQL so balances never corrupt on failures.
- **Idempotency keys** — How duplicate requests (retries, double-clicks) are detected and prevented from double-spending.
- **Sync vs async** — HTTP for instant response; RabbitMQ workers for processing and notifications in the background.
- **Kubernetes locally then in production** — `k3s` dev for the current workspace, MicroK8s as legacy learner content, then EKS/AKS with Terraform and the same core service model.

## Deploy to Kubernetes (short form)

```bash
# k3s dev (current workspace standard)
cd SwiftPay && ./scripts/k8s-dev-deploy.sh

# MicroK8s (legacy learner path)
kubectl apply -k k8s/overlays/local

# AWS EKS (after ./spinup.sh or manual Terraform + bastion + ESO)
IMAGE_TAG=<git-sha> ./k8s/overlays/eks/deploy.sh

# Azure AKS
ACR_NAME=<your-acr> IMAGE_TAG=<git-sha> ./k8s/overlays/aks/deploy.sh
```

**First-time infra setup:** Run **`./spinup.sh`** (AWS or AKS) from the repo root, or see [terraform/README.md](terraform/README.md) / [Infrastructure onboarding](docs/INFRASTRUCTURE-ONBOARDING.md) for the manual apply order.

## Docs

| Document | What's in it |
|----------|-------------|
| **[Contributing & attribution](CONTRIBUTING.md)** | How to contribute; **please give credit** if you reuse this project |
| **[Documentation index](docs/README.md)** | **Start here** — maps every major doc (run, AWS deploy, debug, learn) and marks canonical paths |
| [LEARNING-PATH.md](LEARNING-PATH.md) | Week-by-week curriculum |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Quick symptom → root cause → fix |
| [Services](docs/SERVICES.md) | Endpoints, ports, env vars, queues |
| [Architecture](docs/architecture.md) | Request flow, data model, diagrams |
| [k3s dev](docs/k3s-dev-deployment.md) | Current owned local Kubernetes path for macOS and Linux |
| [MicroK8s](docs/microk8s-deployment.md) | Local Kubernetes deploy and troubleshooting |
| [Local CI/CD](docs/cicd-local.md) | Self-hosted runner + MicroK8s registry + Argo CD |
| [Home lab drills](docs/HOME-LAB-DRILLS.md) | Hands-on break/fix exercises |

**AWS EKS / Terraform:** Follow the order in [docs/README.md](docs/README.md) (onboarding → deployment order → optional quick start). **Having issues?** [TROUBLESHOOTING.md](TROUBLESHOOTING.md), then [docs/troubleshooting.md](docs/troubleshooting.md) for depth. **Local quirks:** [docs/LOCAL-SETUP-GOTCHAS.md](docs/LOCAL-SETUP-GOTCHAS.md). **Ops:** [docs/RUNBOOK.md](docs/RUNBOOK.md).

## Key Features

- **JWT Authentication** - Access tokens with Redis-backed refresh tokens and token blacklisting
- **Async Transaction Processing** - RabbitMQ queues work, workers process in background, users get instant feedback
- **Idempotent Transactions** - Redis at API Gateway + database checks at worker level prevent duplicate charges
- **Atomic Money Transfers** - PostgreSQL transactions with row locking ensure balances never corrupt
- **Circuit Breakers** - Prevents cascading failures when services are down
- **Multi-Cloud Ready** - Deploys to AWS EKS and Azure AKS with Terraform
- **Production Monitoring** - Prometheus metrics, Grafana dashboards, structured logging
