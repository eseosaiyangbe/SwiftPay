# Documentation index

Pick **one** path below. Several files describe overlapping steps (especially AWS deploy); this page names the **canonical** doc for each job so you do not have to open everything.

**Structured learning:** [LEARNING-PATH.md](../LEARNING-PATH.md) (week-by-week).

---

## Run the app

| Goal | Where to go |
|------|-------------|
| MicroK8s (**recommended** for [LEARNING-PATH.md](../LEARNING-PATH.md) Week 1) | [README.md](../README.md) Environment 1 + [microk8s-deployment.md](microk8s-deployment.md) + `./scripts/deploy-microk8s.sh` |
| Docker Compose (fastest, no K8s) | [README.md](../README.md) Environment 2 |
| Local CI/CD (runner + registry + Argo CD) | [cicd-local.md](cicd-local.md) |
| Azure AKS | [README.md](../README.md) short form + `k8s/overlays/aks/` |

---

## AWS EKS infrastructure (first time)

Read in this **order** (do not parallel-read every deploy guide):

| Step | Canonical doc | What it is |
|------|----------------|------------|
| 1 | **[INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md)** | Story, module order, mental model, secrets, “why this before that.” **Start here.** |
| 2 | **[DEPLOYMENT-ORDER.md](DEPLOYMENT-ORDER.md)** | Terraform **targets**, prerequisites checklist, command tables. |
| 3 | Script | From repo root: **`./spinup.sh`** (choose `aws`, workspace) — same order as the table above, plus FinOps. |
| 4 | **[INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md](INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md)** | Long operational guide: SSM bastion, ECR, `deploy.sh` details. Use after onboarding. |
| 5 (optional) | [QUICK-START-INFRA.md](../QUICK-START-INFRA.md) | Extra verification / narrative; **overlaps** 1–3 — use if you want more hand-holding, not a fourth “source of truth.” |
| 6 (optional) | [SPINUP-AND-INFRA-FIXES.md](../SPINUP-AND-INFRA-FIXES.md) | What `spinup.sh` fixed (Redis TLS, ESO, etc.) — context, not a second runbook |

**App onto EKS:** `k8s/overlays/eks/deploy.sh` (see onboarding for when to run it). Local compose / K8s commands and rollback: **[DEPLOYMENT.md](DEPLOYMENT.md)**.

**Terraform entry:** [terraform/README.md](../terraform/README.md) (apply order, bootstrap).

| Terraform deep dives | Where |
|----------------------|--------|
| Hub-and-spoke narrative | [terraform/terraform.md](../terraform/terraform.md) |
| Resource & dependency map | [terraform/ARCHITECTURE-MAP.md](../terraform/ARCHITECTURE-MAP.md) |

---

## Something broke

| Depth | Doc |
|-------|-----|
| Quick symptom → fix | **[TROUBLESHOOTING.md](../TROUBLESHOOTING.md)** (repo root) |
| Long explanations | [troubleshooting.md](troubleshooting.md) |
| Deploy failures only | [DEPLOY-TROUBLESHOOTING.md](DEPLOY-TROUBLESHOOTING.md) |
| Bootstrap / state lock | [BOOTSTRAP-TROUBLESHOOTING.md](BOOTSTRAP-TROUBLESHOOTING.md) |
| Ops habits / health | [RUNBOOK.md](RUNBOOK.md) |

---

## Understand the system

| Topic | Doc |
|-------|-----|
| Big picture | [architecture.md](architecture.md), [system-flow.md](system-flow.md) |
| Why these technologies | [technology-choices.md](technology-choices.md) |
| APIs, ports, env | [SERVICES.md](SERVICES.md) |
| Ingress | [understanding-ingress.md](understanding-ingress.md) |
| Monolith vs microservices | [ARCHITECTURE-MICROSERVICES-VS-MONOLITH.md](ARCHITECTURE-MICROSERVICES-VS-MONOLITH.md) |

---

## Practice & labs

| Doc | Use |
|-----|-----|
| [HOME-LAB-DRILLS.md](HOME-LAB-DRILLS.md) | Timed break/fix exercises on Compose or K8s |
| [LOCAL-SETUP-GOTCHAS.md](LOCAL-SETUP-GOTCHAS.md) | Ports, Apple Silicon, WSL2 |

---

## Debug a specific flow (read one that matches your symptom)

| Doc | Focus |
|-----|--------|
| [how-to-debug-this-system.md](how-to-debug-this-system.md) | General approach |
| [debug-send-money-docker.md](debug-send-money-docker.md) | Send money path (Compose) |
| [tracing-a-single-request.md](tracing-a-single-request.md) | Request tracing |
| [troubleshooting-pending-transactions.md](troubleshooting-pending-transactions.md) | Stuck / pending transactions |
| [transaction-processing-failure-diagnosis.md](transaction-processing-failure-diagnosis.md) | Worker / processing failures |
| [send-money-static-issue-analysis.md](send-money-static-issue-analysis.md) | Historical static/UI analysis |

---

## Security, monitoring, optional cloud

| Doc | Focus |
|-----|--------|
| [SECURITY-AND-RELIABILITY-FIXES.md](SECURITY-AND-RELIABILITY-FIXES.md) | Hardening notes |
| [monitoring.md](monitoring.md) | Prometheus / Grafana / SLOs |
| [bastion-access-guide.md](bastion-access-guide.md) | Bastion access |
| [cloudflare-setup.md](cloudflare-setup.md) | Home lab over HTTPS (optional) |
| [AKS-AMQP-INCOMPATIBILITY.md](AKS-AMQP-INCOMPATIBILITY.md) | AKS + RabbitMQ caveat |

---

## Historical / coaching (optional)

These are **not** required to run or deploy PayFlow:

- [AUDIT-FOLLOW-UP-6.md](AUDIT-FOLLOW-UP-6.md) — audit follow-up notes  
- [EKS-MIGRATION-MENTEE-INSTRUCTIONS.md](EKS-MIGRATION-MENTEE-INSTRUCTIONS.md) — mentee migration steps  
- [payflow-platform-design.md](payflow-platform-design.md) — design narrative (may overlap architecture docs)

---

## CI/CD (cloud vs local)

| What | Where |
|------|--------|
| GitHub-hosted runners (Docker Hub / ECR / ACR) | [.github/workflows/build-and-deploy.yml](../.github/workflows/build-and-deploy.yml) (header comments list secrets) |
| MicroK8s + self-hosted runner + Argo CD | [cicd-local.md](cicd-local.md) |
