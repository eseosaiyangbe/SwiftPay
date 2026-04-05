# PAYFLOW — Infrastructure & Deployment Guide

**AWS EKS • K8s 1.32 • Node 22 • Terraform 1.5+**  
March 2026 | v3.0 (post-audit)

> **Navigation:** Read [INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md) first for the full story and module order. Use [DEPLOYMENT-ORDER.md](DEPLOYMENT-ORDER.md) for target-by-target Terraform. This guide is the **deep operational** companion (bastion, SSM, ECR, deploy). **Index:** [README.md](README.md).

---

## 0 Overview

PayFlow runs on private AWS EKS. The cluster endpoint has no public access — all `kubectl` operations go through the bastion host via SSM. Your local machine never touches the Kubernetes API directly.

**INFO** Full deploy from zero takes ~90 minutes. Infrastructure is provisioned once. Subsequent app-only deploys take 3–5 minutes.

### Architecture at a Glance

| Layer | What it is | How you reach it |
|-------|------------|------------------|
| Your machine | Mac/Linux with AWS CLI, Docker, kubectl | Runs `spinup.sh` and `deploy.sh` locally |
| Hub VPC | Transit Gateway + bastion host (Ubuntu 24) | SSM: `aws ssm start-session --target <id>` |
| Spoke VPC | EKS cluster, private subnets, NAT, VPC endpoints | Via bastion only — no direct access |
| EKS Nodes | 2× t3.large SPOT, AL2023, K8s 1.32 | SSM to node for low-level debugging only |
| ECR | 6 private repos, KMS-encrypted, immutable tags | `build-push-ecr.sh` from your machine |
| Managed Services | RDS PostgreSQL, ElastiCache Redis, Amazon MQ | Via app pods — ESO injects credentials |
| Secrets Manager | All credentials — ESO syncs to K8s Secrets | `aws secretsmanager get-secret-value` (read) |

---

## 1 Prerequisites

### 1.1 Required Tools

| Tool | Version | Check |
|------|---------|--------|
| AWS CLI | v2.x | `aws --version` |
| Terraform | 1.5.0+ | `terraform version` |
| Docker | 24+ | `docker --version` |
| kubectl | 1.32.x | `kubectl version --client` |
| SSM Session Manager Plugin | latest | `session-manager-plugin --version` |
| Python 3 | 3.8+ | `python3 --version` |
| perl | any (used by deploy.sh) | `perl --version` |

### 1.2 IAM Permissions

The IAM identity running deployments needs:

| AWS Service | Why it is needed |
|-------------|------------------|
| ec2, vpc, eks, ecr, rds, elasticache, mq | Infrastructure provisioning and management |
| iam:CreateRole, AttachRolePolicy, PassRole | IRSA roles for ESO, cluster-autoscaler, ECR nodes |
| secretsmanager, kms | Secrets creation and KMS key grants |
| s3, dynamodb | Terraform state backend (bucket + lock table) |
| ssm:SendCommand, ssm:GetCommandInvocation | Remote execution on bastion from local machine |
| wafv2, guardduty, cloudtrail, config | Security services provisioned by spinup.sh |

### 1.3 Sensitive Variables — Set Before Anything Else

**WARN** These three values are never auto-generated. Terraform will prompt and fail if they are missing. Set them once per shell session.

```bash
# Generate cryptographically strong values
export TF_VAR_db_password=$(openssl rand -base64 32)
export TF_VAR_mq_password=$(openssl rand -base64 32)
export TF_VAR_jwt_secret=$(openssl rand -base64 48)

# Optional — override defaults
export AWS_REGION=us-east-1      # default: us-east-1
export TF_WORKSPACE=dev          # default: dev  (use 'prod' for production)
```

**CRITICAL** Save these values in a password manager immediately. If lost, all credentials must be rotated after re-deploy.

---

## 2 First Deploy (Zero to Running)

Use `spinup.sh` for first-time provisioning. It runs all Terraform modules in order, verifies Secrets Manager population, and leaves the cluster ready to receive app images.

### 2.1 Run spinup.sh

```bash
cd /path/to/payflow

# Set the three required secrets (see 1.3)
export TF_VAR_db_password=$(openssl rand -base64 32)
export TF_VAR_mq_password=$(openssl rand -base64 32)
export TF_VAR_jwt_secret=$(openssl rand -base64 48)

./spinup.sh
```

**spinup.sh** applies modules in this exact order — each depends on the previous:

| Step | Module | Duration | Description |
|------|--------|----------|-------------|
| 1 | Backend Bootstrap | ~2 min | S3 bucket `payflow-tfstate-ACCOUNT` + DynamoDB lock table. Patches all `backend.tf` files with your account ID. |
| 2 | Hub VPC | ~3 min | Transit Gateway, public subnet for bastion, private subnet for shared services. |
| 3 | Spoke VPC + EKS | ~45 min | VPC, private subnets, NAT, VPC endpoints (ECR/S3/STS/Secrets Manager), EKS 1.32, 2× t3.large SPOT nodes, IRSA, bootstrap node. |
| 4 | Managed Services | ~25 min | RDS PostgreSQL 16, ElastiCache Redis 7, Amazon MQ RabbitMQ 3.13. EKS security groups resolved by tag. |
| 5 | Secrets Verification | — | Confirms RDS host, Redis URL, RabbitMQ URL in Secrets Manager. |
| 6 | Bastion Host | ~3 min | Ubuntu 24.04 in Hub VPC. SSM-accessible. Pre-installed: kubectl, Helm, AWS CLI (see §7.4). |
| 7 | FinOps | ~2 min | AWS Budgets, anomaly detection, billing alarm. |

**INFO** Total for a fresh account: ~90 minutes. Subsequent `spinup.sh` runs are fast — Terraform only applies changes.

### 2.2 Verify Infrastructure

```bash
# All outputs should be populated
cd terraform/aws/spoke-vpc-eks && terraform output
# Key outputs: eks_cluster_endpoint, ecr_repository_urls,
#              external_secrets_irsa_arn, waf_web_acl_arn

# Get the SSM command to connect to bastion
cd ../bastion && terraform output ssm_connect_command
# Prints: aws ssm start-session --target i-XXXXXXXXXX --region us-east-1
```

### 2.3 Verify EKS Nodes Are Ready (from Bastion)

```bash
# Connect to bastion — no SSH key required
$(cd terraform/aws/bastion && terraform output -raw ssm_connect_command)

# ── Inside the bastion session ──────────────────────────
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

kubectl get nodes
# NAME                           STATUS   ROLES    AGE   VERSION
# ip-10-x-x-x.ec2.internal       Ready    <none>   5m    v1.32.x
# ...

kubectl get pods -n kube-system
# Expect Running: coredns (×2), aws-node (×2), kube-proxy (×2),
#                 aws-load-balancer-controller, cluster-autoscaler,
#                 external-secrets, metrics-server

exit
```

If `aws` or `kubectl` are not found on the bastion, see **§7.4 Bastion SSM and CLI setup**.

---

## 3 Build and Push Images to ECR

**Run this from your local machine (normal CLI), not from the bastion.** You need Docker and the repo on your machine to build images; the bastion is only for `kubectl`/SSM access to the private EKS API.

**WARN** ECR repos use immutable tags. You cannot overwrite an existing tag. Always push with a new version identifier. `deploy.sh` aborts if any image is missing.

### 3.1 Choose a Tag

```bash
# Git SHA — recommended
export IMAGE_TAG=$(git rev-parse --short HEAD)

# Semantic version
export IMAGE_TAG=v1.2.3

# Date-based
export IMAGE_TAG=$(date +%Y%m%d-%H%M)
```

### 3.2 Build and Push All Services

```bash
# From repo root
./scripts/build-push-ecr.sh $IMAGE_TAG
```

Build context is `./services/` (includes `shared/`). Do not use a per-service context or you get module-not-found at runtime.

Services: api-gateway, auth-service, wallet-service, transaction-service, notification-service, frontend.

### 3.3 If a Tag Already Exists

Use a new tag and re-run `./scripts/build-push-ecr.sh $IMAGE_TAG`.

---

## 4 Deploy to EKS

Run `deploy.sh` from your local machine. It builds the Kustomize manifest, uploads to S3, then runs an SSM command on the bastion to execute `kubectl`. No manual bastion steps are needed.

### 4.1 Run deploy.sh

```bash
cd k8s/overlays/eks
IMAGE_TAG=$IMAGE_TAG ./deploy.sh

# With explicit environment:
TF_WORKSPACE=prod IMAGE_TAG=v1.2.3 ./deploy.sh

# Non-interactive / CI:
DEPLOY_AUTO_CONFIRM=yes IMAGE_TAG=$IMAGE_TAG ./deploy.sh

# Verbose:
DEBUG=1 IMAGE_TAG=$IMAGE_TAG ./deploy.sh
```

### 4.2 What deploy.sh Does

1. Pre-flight: aws, kubectl, perl; STS get-caller-identity.
2. Locate bastion (tagged instance).
3. Check RDS and ElastiCache are available.
4. Build Kustomize, substitute placeholders, validate.
5. ECR image pre-flight — abort if any image missing.
6. Upload manifest and script to S3.
7. SSM send-command to bastion; stream output.
8. Bastion: ESO Helm upgrade, CRD wait, ClusterSecretStore and ExternalSecret sync.
9. Bastion: DB migration job (up to 10 min).
10. Bastion: `kubectl apply` and rollout status per service.

---

## 5 Verify the Deployment

### 5.1 From the Bastion

```bash
$(cd terraform/aws/bastion && terraform output -raw ssm_connect_command)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

kubectl get pods -n payflow
kubectl get ingress -n payflow
ALB=$(kubectl get ingress payflow-ingress -n payflow -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ALB/health
# Expected: {"status":"ok"}
```

### 5.2 Health Check Reference

| Check | Command / URL | Expected |
|-------|----------------|----------|
| API Gateway health | `curl http://$ALB/health` | `{"status":"ok"}` |
| Frontend | `curl http://$ALB/` | HTML with React app |
| ESO sync | `kubectl get externalsecret -n payflow` | READY=True, STATUS=SecretSynced |
| ClusterSecretStore | `kubectl get clustersecretstore` | READY=True |
| HPA | `kubectl get hpa -n payflow` | current/target replicas |
| Nodes | `kubectl get nodes` | 2 nodes, STATUS=Ready |

### 5.3 Verify Secrets Populated

```bash
kubectl get secret db-secrets -n payflow -o json | python3 -c \
  "import sys,json,base64; d=json.load(sys.stdin); [print(k) for k in d['data']]"
# Expected keys: DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, JWT_SECRET,
#                RABBITMQ_USER, RABBITMQ_PASSWORD, RABBITMQ_URL, REDIS_URL
```

---

## 6 Subsequent Deploys (App Only)

Do **not** re-run `spinup.sh` unless Terraform changed. Standard flow:

```bash
export IMAGE_TAG=$(git rev-parse --short HEAD)
./scripts/build-push-ecr.sh $IMAGE_TAG
cd k8s/overlays/eks && IMAGE_TAG=$IMAGE_TAG ./deploy.sh
# Total time: ~3–5 minutes
```

---

## 7 Bastion Access Reference

### 7.1 Connect

```bash
# Primary — SSM (no SSH key, no port 22 required)
$(cd terraform/aws/bastion && terraform output -raw ssm_connect_command)
# or:
aws ssm start-session --target <bastion-instance-id> --region us-east-1

# SSH (only if authorized_ssh_cidrs set in bastion variables)
ssh -i ~/.ssh/your-key.pem ubuntu@$(cd terraform/aws/bastion && terraform output -raw bastion_public_ip)
```

### 7.2 kubectl on Bastion

At the start of every bastion session:

```bash
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl get nodes && kubectl get pods -n payflow
```

### 7.3 Common kubectl Commands

See the full list in the original guide (pods, deployments, secrets/ESO, networking, HPA).

### 7.4 Bastion SSM and CLI setup (what we fixed)

The bastion is Ubuntu 24.04, SSM-only. For SSM and `kubectl`/AWS CLI to work reliably, the following is in place and what to do if something is missing.

**Outbound connectivity**

- The bastion security group **must** allow outbound **TCP 80** (HTTP) in addition to 443 (HTTPS) and 53 (DNS). Terraform does this in `terraform/aws/bastion/main.tf`:
  - **HTTPS (443):** EKS API, SSM, and package repos.
  - **HTTP (80):** `apt` and binary downloads (e.g. AWS CLI installer, kubectl). Without port 80, `apt-get update` and many `curl` installs fail (e.g. "Network is unreachable", "Package 'awscli' has no installation candidate").
- If the bastion was created before this egress rule existed, run `terraform apply` in `terraform/aws/bastion` so the rule is added, then retry installs or reconnect via SSM.

**AWS CLI on the bastion**

- Ubuntu 24.04 does **not** ship `awscli` in apt. The bastion **user_data** installs **AWS CLI v2** via the official installer (download to `/tmp`, unzip, run `install`). Do not rely on `apt-get install awscli`.
- If AWS CLI is missing or broken, from the bastion (e.g. via SSM):

  ```bash
  cd /tmp
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -q awscliv2.zip
  sudo ./aws/install
  rm -rf aws awscliv2.zip
  aws --version
  ```

**kubectl on the bastion**

- user_data installs `kubectl` by downloading the binary. If the script runs in a directory where the process cannot write (e.g. permission denied), the download can fail with `curl: (23) Failure writing output to destination` and `kubectl` will be missing.
- **Fix:** download to a writable directory, then move into place:

  ```bash
  cd /tmp
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
  kubectl version --client
  ```

  Then run `aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1` and `kubectl get nodes`.

**Helm on the bastion**

- user_data installs Helm via the get-helm-3 script. If that step failed (e.g. earlier apt/curl failure), Helm will be missing (`helm: not found`).
- **Fix:** from the bastion (SSM session):

  ```bash
  cd /tmp
  curl -sSfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version
  ```

  If the script fails, install the binary directly:

  ```bash
  cd /tmp
  HELM_VER="v3.16.3"
  curl -sSL "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz" -o helm.tar.gz
  tar -xzf helm.tar.gz
  sudo mv linux-amd64/helm /usr/local/bin/
  rm -rf linux-amd64 helm.tar.gz
  helm version
  ```

**Summary**

| Issue | Cause | Fix |
|-------|--------|-----|
| apt/curl "Network is unreachable" or "no installation candidate" | No outbound TCP 80 | Add egress rule in `terraform/aws/bastion/main.tf` (already present), apply, retry. |
| `aws: command not found` | No AWS CLI v2 on Ubuntu 24 | Install AWS CLI v2 via official installer (see above), not apt. |
| `kubectl` missing or `chmod: cannot access 'kubectl'` | Download wrote to a read-only dir | `cd /tmp`, download kubectl, `chmod +x kubectl`, `sudo mv kubectl /usr/local/bin/`. |
| `helm: not found` | Helm install step in user_data failed or never ran | Run get-helm-3 script from `/tmp`, or install binary from get.helm.sh (see above). |

After these, SSM sessions can run `aws eks update-kubeconfig`, `kubectl`, and `helm` as in §2.3 and §5.1.

---

## 8 Troubleshooting

### 8.1 ImagePullBackOff / ErrImagePull

- Image in ECR: `aws ecr describe-images --repository-name payflow-eks-cluster/api-gateway --image-ids imageTag=$TAG`
- Manifest tag: `kubectl describe pod <n> -n payflow | grep Image:`
- KMS decrypt: ensure node role has `kms:Decrypt` on ECR key.
- VPC: ensure ECR API/DKR endpoints exist in Spoke VPC.

### 8.2 Pods Stuck in Pending

`kubectl describe pod <pod-name> -n payflow` — check Events. Typical: insufficient CPU (need 2 nodes), or node taints.

### 8.3 CrashLoopBackOff

`kubectl logs deployment/<service> -n payflow --previous`. Common: wrong Docker context (use `./services/`), RDS/Redis unreachable (SG/NetworkPolicy), ESO not synced (db-secrets empty), wrong DB password in Secrets Manager.

### 8.4 External Secrets Not Syncing

Check ESO pod, ClusterSecretStore Ready, and IRSA annotation on `external-secrets` service account. Re-run deploy or annotate and restart ESO.

### 8.5 DB Migration Job Failed

`kubectl logs job/db-migration-job -n payflow`. Fix RDS/credentials in Secrets Manager if needed. On EKS, **`db-secrets` is created only by External Secrets Operator** (the base placeholder secret is not in the EKS overlay).

**"CreateContainerConfigError"** — The migration pod cannot start because the Secret `db-secrets` does not exist or is not populated yet. The deploy script now waits for the secret to exist (and for `DB_HOST` to be set) before creating the migration job. If you see this after a deploy, ESO may not have synced: check `kubectl get externalsecret -n payflow`, `kubectl describe externalsecret db-secrets-external -n payflow`, and ESO pod logs; ensure IRSA is set and AWS Secrets Manager has the expected keys (e.g. `payflow/ENV/rds` with `host`, `username`, `password`, `port`).

**"postgres:5432 - no response" / "RDS not ready, waiting..."** — The migration pod is using wrong or empty `DB_HOST` (so it tries `postgres:5432` instead of the RDS endpoint). This can happen if the secret was recreated with placeholders and the job started before ESO synced. Re-run deploy **from repo root** so ESO IRSA is set and the script does not delete `db-secrets`; the new job pod will read the synced secret and complete. Then run `kubectl rollout restart deployment -n payflow` so app pods get the correct env.

### 8.6 Backend pods CrashLoopBackOff / 503 on health

auth-service, wallet-service, transaction-service, or notification-service show **503** on liveness/readiness or **CrashLoopBackOff**. Logs often show `getaddrinfo ENOTFOUND postgres` or `ENOTFOUND redis`/`rabbitmq` — the pod is using **placeholder hostnames** (postgres, redis, rabbitmq) instead of the real RDS/ElastiCache/Amazon MQ endpoints. On EKS this meant the `db-secrets` used at pod start had placeholder values; the base no longer ships a placeholder secret for EKS (ESO is the only source), so after a clean deploy new pods get correct values. For existing broken pods, restart so they pick up the current secret.

**On the bastion, run:**

```bash
# 1. Did the migration job complete?
kubectl get job db-migration-job -n payflow
kubectl logs job/db-migration-job -n payflow --tail=30

# 2. What error is the app hitting?
kubectl logs deployment/auth-service -n payflow --previous --tail=80
```

**If migration job never completed** (logs show "postgres:5432 - no response" or "RDS not ready, waiting...") — the job had wrong/empty `DB_HOST`. Re-run deploy **from repo root** so the script gets ESO IRSA and does not delete `db-secrets`; the new job will use the synced secret and complete. Then restart app deployments so new pods get correct env:

```bash
kubectl rollout restart deployment -n payflow
kubectl rollout status deployment -n payflow --timeout=300s
```

**If migration completed but apps still 503** — check app logs for `ECONNREFUSED`, `password authentication failed`, or `relation "users" does not exist`. Ensure RDS security group (Terraform managed-services) allows ingress from EKS node and cluster SGs; ensure `db-secrets` has the correct keys (see §5.3). Then `kubectl rollout restart deployment -n payflow`.

**One-time fix if pods still see "postgres"/"redis"/"rabbitmq"** — If you deployed before the EKS overlay stopped shipping the placeholder secret, the in-cluster `db-secrets` may have been created with placeholders and ESO merge may not overwrite all keys. From the bastion: `kubectl delete secret db-secrets -n payflow`. ESO will recreate it from AWS Secrets Manager within a short time. Then `kubectl rollout restart deployment -n payflow` and re-run the migration (delete job and re-apply, or run `deploy.sh` again from repo root).

### 8.7 SSM send-command Fails

Local IAM needs `ssm:SendCommand`, `ssm:GetCommandInvocation`. Test:

```bash
aws ssm send-command --document-name AWS-RunShellScript \
  --instance-ids $BASTION_ID \
  --parameters 'commands=["echo test"]' \
  --region us-east-1
```

If it still fails, connect manually and run the bootstrap command printed by `deploy.sh`:

```bash
aws ssm start-session --target $BASTION_ID --region us-east-1
```

Ensure the bastion has outbound 80/443 (see §7.4) so any install or download from the bastion can succeed.

### 8.8 Deploy script finished — checking result

When the deploy script finishes, the shell prompt returns. The SSM command has completed and the script has exited.

**Check the result**

Scroll up in that terminal. Right after the row of dots you should see either:

- **Success:**  
  `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`  
  `  ✓ Deployment succeeded!`
- **Failure:**  
  `[error]   Deployment failed on bastion (Status: ...)`  
  and possibly a "Bastion stderr" block.

The `%` after the dots is from zsh when the last line doesn't end with a newline; it's harmless.

**If you don't see success or error**

The script may have exited without printing the final block. Inspect that run with (replace `COMMAND_ID` and `BASTION_ID` with the values printed during deploy):

```bash
aws ssm get-command-invocation \
  --command-id <COMMAND_ID> \
  --instance-id <BASTION_ID> \
  --region us-east-1 \
  --query '[Status, StandardOutputContent, StandardErrorContent]' \
  --output text
```

That shows whether the command **Succeeded** or **Failed** and the full bastion stdout/stderr.

**Streaming behaviour**

The deploy script polls SSM every 5 seconds and prints new bastion output as it arrives. You should see `[bastion] ...` lines during the run; if output is large or slow, you may still see dots until a chunk arrives. After the command completes, the script prints any remaining output and then the success or error message.

### 8.9 Ingress has no ADDRESS (ALB never created)

If `kubectl get ingress -n payflow` shows empty **ADDRESS** for several minutes, the AWS Load Balancer Controller may not be running or may be failing to create the ALB.

**On the bastion** (after `aws ssm start-session --target <BASTION_ID> --region us-east-1`):

```bash
# 1) Is the controller running?
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 2) If no pods or not Running, check for the Helm release
helm list -n kube-system | grep -i load

# 3) Controller logs (if the pod exists)
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

- **No controller pods** — The bootstrap node may have failed or self-terminated before the controller was installed. Install it manually (from bastion):

  ```bash
  CLUSTER_NAME="payflow-eks-cluster"
  AWS_REGION="us-east-1"
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=payflow-eks-vpc" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
  ALB_IRSA_ARN=$(terraform -chdir=/path/to/terraform/aws/spoke-vpc-eks output -raw alb_controller_irsa_arn 2>/dev/null || aws iam list-roles --query "Roles[?contains(RoleName,'alb-controller')].Arn" --output text --region $AWS_REGION | awk '{print $1}')

  helm repo add eks https://aws.github.io/eks-charts
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_IRSA_ARN" \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID"
  ```

  (Get `ALB_IRSA_ARN` from your machine: `terraform -chdir=terraform/aws/spoke-vpc-eks output -raw alb_controller_irsa_arn` then paste into the bastion.)

- **Controller running but ALB not created** — In controller logs look for `error` or `Unable to create LoadBalancer`. Common causes: subnets not tagged with `kubernetes.io/role/elb` (Terraform spoke-vpc-eks sets this on public subnets), or IAM permissions. Fix subnet tags or IRSA policy then restart the controller.

After the controller is healthy, the Ingress **ADDRESS** should populate within a few minutes.

---

## 9 Tear Down

**WARN** `destroy.sh` destroys in dependency order and prompts before each module. S3 state bucket and DynamoDB lock table are never destroyed.

```bash
export TF_VAR_db_password='...'
export TF_VAR_mq_password='...'
export TF_VAR_jwt_secret='...'
./destroy.sh
```

Order: managed-services → spoke-vpc-eks → bastion → hub-vpc. After full destroy, only the S3 state bucket remains (~$0.02/month).

---

## 10 Cost Reference (dev)

| Resource | Config | Est. monthly |
|----------|--------|--------------|
| EKS Control Plane | 1 cluster | ~$73 |
| EKS Nodes | 2× t3.large SPOT | ~$25 |
| NAT Gateway | 1 + data | ~$32+ |
| VPC Endpoints | ECR, STS, Secrets Manager | ~$28 |
| RDS PostgreSQL | db.t3.micro, single-AZ | ~$15 |
| ElastiCache Redis | cache.t3.micro | ~$12 |
| Amazon MQ | mq.t3.micro | ~$18 |
| ECR, Secrets Manager, ALB, S3/DynamoDB | — | ~$22 |
| **Total** | | **~$226/month** |

Destroy when not in use to reduce to ~$0.02/month (S3 only).

---

## 11 Environment Variable Reference

**deploy.sh:** `IMAGE_TAG`, `TF_WORKSPACE`, `AWS_REGION`, `DEPLOY_AUTO_CONFIRM`, `DEBUG`.

**spinup.sh / Terraform:** `TF_VAR_db_password`, `TF_VAR_mq_password`, `TF_VAR_jwt_secret` (required); `TF_WORKSPACE`, `AWS_REGION`.
