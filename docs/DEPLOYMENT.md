# Deployment & Rollback

> **📋 Terraform order / targets:** [DEPLOYMENT-ORDER.md](DEPLOYMENT-ORDER.md). **Full AWS story:** [INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md). **Doc index:** [README.md](README.md).

## Local Development

```bash
# Start everything
docker-compose up -d

# Check all services are healthy
docker-compose ps

# Logs for specific service
docker-compose logs -f api-gateway

# Stop everything
docker-compose down

# Reset everything including volumes (wipe DB)
docker-compose down -v
```

## Database Migrations

**Docker Compose:** Migrations run automatically on PostgreSQL startup (mounted to `/docker-entrypoint-initdb.d`)

**Manual migration (if needed):**
```bash
# Using Flyway CLI (requires Flyway installed)
flyway -configFiles=flyway.conf migrate

# Check migration status
flyway -configFiles=flyway.conf info

# Or run SQL directly
docker-compose exec postgres psql -U swiftpay -d swiftpay -f /docker-entrypoint-initdb.d/V1__initial_schema.sql
```

**Migration files location:** `migrations/`
- `V1__initial_schema.sql` - Users, wallets, transactions, notifications tables
- `V2__add_indexes.sql` - Performance indexes
- `V3__add_2fa.sql` - Two-factor authentication columns

**Rollback:** Manual SQL required - Flyway doesn't auto-rollback. Connect to database and run reverse migration SQL.

## Bootstrap Infrastructure (First Time Only)

```bash
# Creates S3 + DynamoDB for Terraform state (AWS)
cd terraform
./bootstrap.sh --aws-only

# Or both clouds
./bootstrap.sh

# Creates backend.tf files for all modules automatically
# Uses your AWS account ID (no manual replacement needed)
```

**What it creates:**
- S3 bucket: `swiftpay-tfstate-{ACCOUNT_ID}` (versioned, encrypted)
- DynamoDB table: `swiftpay-tfstate-lock` (state locking)
- `backend.tf` files for: `hub-vpc`, `spoke-vpc-eks`, `managed-services`, `bastion`

## Deploy to AWS EKS

**📋 Before you start:** See [Deployment Order Guide](DEPLOYMENT-ORDER.md) for:
- Complete prerequisites checklist
- Step-by-step deployment with Terraform targets
- Time estimates and verification steps
- Common issues and rollback procedures

**Quick start (automated):**

```bash
cd k8s/overlays/eks
./deploy.sh
```

The script automatically handles:
- AWS Account ID detection and replacement
- Environment detection (dev/prod) from Terraform workspace
- Terraform backend file verification (runs bootstrap if needed)
- Kustomize validation before deployment
- Prompts for deployment confirmation

**Manual deployment (using targets to avoid dependency issues):**

```bash
# Step 1: Bootstrap infrastructure (first time only)
cd terraform
./bootstrap.sh --aws-only
# This creates S3 bucket, DynamoDB table, and backend.tf files for all modules

# Step 2: Deploy infrastructure in order
cd aws/hub-vpc
terraform init && terraform workspace new dev
terraform apply

cd ../spoke-vpc-eks
terraform init && terraform workspace select dev
terraform plan -out=tfplan

# Apply in correct order (explain WHY this order)
# 1. VPC first (networking foundation)
terraform apply -target=module.networking

# 2. CNI addon before nodes (required for pod networking)
terraform apply -target=aws_eks_addon.vpc_cni

# 3. Nodes after CNI (pods need networking)
terraform apply -target=aws_eks_node_group.on_demand

# 4. Everything else (cluster, addons, secrets)
terraform apply

# Step 3: Deploy managed services (RDS, MQ, Redis)
cd ../managed-services
terraform init && terraform workspace select dev
terraform apply
# Note: null_resource automatically updates Secrets Manager with RDS/MQ endpoints

# Step 4: Deploy application (automated script handles all pre-deployment steps)
cd ../../k8s/overlays/eks
./deploy.sh
# OR manually: kubectl apply -k . (after running pre-deployment steps from "Important Pre-Deployment Steps" section)
```

**Why this order:**
- VPC must exist before EKS cluster
- VPC CNI addon must be installed before nodes join (pods need IP addresses)
- Nodes must exist before CoreDNS addon (DNS needs nodes)
- Application needs cluster + nodes ready

## Deploy Applications to EKS (After Infrastructure is Ready)

**Prerequisites:**
- ✅ EKS cluster is running (`kubectl get nodes` shows Ready nodes)
- ✅ Managed services are deployed (RDS, ElastiCache, Amazon MQ)
- ✅ `kubectl` is configured for your EKS cluster
- ✅ AWS CLI is configured and you're logged in

### Step 1: Configure kubectl for EKS

```bash
# Get cluster name and region from Terraform output
cd terraform/aws/spoke-vpc-eks
terraform output eks_cluster_name
terraform output eks_cluster_endpoint

# Configure kubectl (replace with your cluster name and region)
aws eks update-kubeconfig \
  --name swiftpay-eks-cluster \
  --region us-east-1

# Verify connection
kubectl cluster-info
kubectl get nodes
```

### Step 2: Verify Infrastructure is Ready

```bash
# Check nodes are Ready
kubectl get nodes

# Check managed services endpoints (from Terraform)
cd terraform/aws/managed-services
terraform output rds_endpoint
terraform output elasticache_endpoint
terraform output mq_endpoint

# Verify Secrets Manager has secrets
aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'swiftpay')]"
```

### Step 3: Deploy Applications

**Option A: Automated (Recommended)**

```bash
cd k8s/overlays/eks
./deploy.sh
```

The script will:
1. ✅ Verify Terraform backend files exist
2. ✅ Get your AWS Account ID automatically
3. ✅ Replace `<ACCOUNT_ID>` in `kustomization.yaml`
4. ✅ Set environment (dev/prod) in `eks-external-secrets.yaml`
5. ✅ Validate Kustomize build
6. ✅ Prompt for confirmation
7. ✅ Deploy all services with `kubectl apply -k .`

**Option B: Manual Deployment**

```bash
cd k8s/overlays/eks

# Step 1: Replace <ACCOUNT_ID> placeholder
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i '' "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" kustomization.yaml

# Step 2: Set environment in secrets (replace ENV with dev or prod)
sed -i '' "s|swiftpay/ENV/|swiftpay/dev/|g" eks-external-secrets.yaml

# Step 3: Preview what will be deployed
kubectl kustomize . | less

# Step 4: Deploy
kubectl apply -k .
```

### Step 4: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n swiftpay

# Check services
kubectl get svc -n swiftpay

# Check database migration job
kubectl get jobs -n swiftpay
kubectl logs -n swiftpay job/db-migration-job

# Check API Gateway logs
kubectl logs -n swiftpay deployment/api-gateway -f

# Test health endpoint
kubectl port-forward -n swiftpay svc/api-gateway 3000:3000
curl http://localhost:3000/health
```

### Step 5: Access the Application

**Via Port Forward (for testing):**
```bash
# Forward API Gateway
kubectl port-forward -n swiftpay svc/api-gateway 3000:3000

# Forward Frontend
kubectl port-forward -n swiftpay svc/frontend 80:80

# Access in browser
open http://localhost
```

**Via Ingress (production):**
```bash
# Get ingress URL
kubectl get ingress -n swiftpay

# Access via ALB URL (from AWS Load Balancer Controller)
```

### Troubleshooting

**Pods not starting:**
```bash
# Check pod events
kubectl describe pod <pod-name> -n swiftpay

# Check logs
kubectl logs <pod-name> -n swiftpay

# Common issues:
# - ImagePullBackOff: Check ECR permissions and image URL
# - CrashLoopBackOff: Check application logs
# - Pending: Check node resources and taints
```

**Cannot connect to database:**
```bash
# Verify secrets exist
kubectl get secret db-secrets -n swiftpay -o yaml

# Check External Secrets Operator (if using)
kubectl get externalsecret -n swiftpay
kubectl describe externalsecret db-secrets-external -n swiftpay

# Verify RDS endpoint matches ConfigMap
kubectl get configmap app-config -n swiftpay -o yaml | grep DB_HOST
```

**Network policies blocking traffic:**
```bash
# Check network policies
kubectl get networkpolicies -n swiftpay

# Temporarily disable for testing (NOT for production)
kubectl delete networkpolicy default-deny-all -n swiftpay
```

## Deploy to Azure AKS

```bash
# Initialize Terraform
cd terraform/azure/spoke-vnet-aks
terraform init
terraform workspace select dev

# Plan
terraform plan -out=tfplan

# Apply infrastructure
terraform apply

# Deploy application
kubectl apply -k k8s/overlays/aks
```

## Important Pre-Deployment Steps

**✅ Automated:** All pre-deployment steps are handled automatically by `k8s/overlays/eks/deploy.sh`.

The script automatically:
- Fetches AWS Account ID from your AWS CLI session
- Replaces `<ACCOUNT_ID>` placeholder in `kustomization.yaml`
- Sets environment (dev/prod) in `eks-external-secrets.yaml` based on Terraform workspace
- Verifies Terraform backend files exist (runs bootstrap if missing)
- Validates Kustomize build before deployment

**Manual alternative** (if you prefer not to use the script):

### Replace <ACCOUNT_ID> in EKS Overlay

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i.bak "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" k8s/overlays/eks/kustomization.yaml
```

**Why:** The placeholder causes `ImagePullBackOff` errors. Pods can't pull images from a non-existent ECR registry.

### Update Secret Paths for Environment

The `eks-external-secrets.yaml` uses `swiftpay/ENV/` placeholders. Replace `ENV` with your environment:

```bash
# For dev
sed -i.bak "s|swiftpay/ENV/|swiftpay/dev/|g" k8s/overlays/eks/eks-external-secrets.yaml

# For prod
sed -i.bak "s|swiftpay/ENV/|swiftpay/prod/|g" k8s/overlays/eks/eks-external-secrets.yaml
```

### Verify Backend Files Exist

Before running `terraform init` in any module, ensure `backend.tf` exists:

```bash
# Check if backend.tf exists
ls terraform/aws/hub-vpc/backend.tf
ls terraform/aws/managed-services/backend.tf
ls terraform/aws/bastion/backend.tf

# If missing, run bootstrap first
cd terraform && ./bootstrap.sh --aws-only
```

**Why:** Without `backend.tf`, Terraform uses local state which gets lost. Bootstrap generates these files automatically.

## Rollback

### Application (< 2 minutes)

```bash
# Immediate rollback to previous version
kubectl rollout undo deployment/api-gateway -n swiftpay

# Rollback to specific version
kubectl rollout history deployment/api-gateway -n swiftpay
kubectl rollout undo deployment/api-gateway --to-revision=2 -n swiftpay

# Verify rollback worked
kubectl rollout status deployment/api-gateway -n swiftpay
kubectl get pods -n swiftpay -l app=api-gateway
```

### Database (15-30 minutes)

```bash
# Snapshot before every migration (run this BEFORE migrating)
aws rds create-db-snapshot \
  --db-instance-identifier swiftpay-postgres \
  --db-snapshot-identifier pre-migration-$(date +%Y%m%d)

# Restore from snapshot (last resort)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier swiftpay-postgres-restored \
  --db-snapshot-identifier pre-migration-20260113
```

**Note:** Restoring creates a NEW database instance. Update application connection strings after restore.

### Infrastructure (Terraform)

```bash
# Restore previous state from S3 versioning
aws s3 cp s3://swiftpay-tfstate-{ACCOUNT_ID}/env:/dev/aws/spoke-vpc-eks/terraform.tfstate \
  terraform.tfstate --version-id {version-id}

# Fix specific broken resource without touching others
terraform apply -target=aws_eks_node_group.on_demand
```

### Secrets Manager Updates

**After deploying managed-services (RDS, MQ):**

The `null_resource` in `managed-services/rds.tf` and `managed-services/mq.tf` automatically updates Secrets Manager with actual endpoints. If it fails (e.g., secret doesn't exist yet), run manually:

```bash
# Get RDS endpoint from Terraform output
cd terraform/aws/managed-services
RDS_ENDPOINT=$(terraform output -raw rds_address)

# Update RDS secret with endpoint
aws secretsmanager put-secret-value \
  --secret-id swiftpay/dev/rds \
  --secret-string "{\"username\":\"swiftpay\",\"password\":\"YOUR_PASSWORD\",\"host\":\"${RDS_ENDPOINT}\",\"port\":5432,\"dbname\":\"swiftpay\",\"engine\":\"postgres\"}"

# Get MQ endpoint from Terraform output
MQ_ENDPOINT=$(terraform output -raw mq_amqp_endpoint | sed 's|amqps://||' | cut -d: -f1)
MQ_URL="amqps://swiftpay:YOUR_PASSWORD@${MQ_ENDPOINT}:5671"

# Update RabbitMQ secret with endpoint and URL
aws secretsmanager put-secret-value \
  --secret-id swiftpay/dev/rabbitmq \
  --secret-string "{\"username\":\"swiftpay\",\"password\":\"YOUR_PASSWORD\",\"endpoint\":\"${MQ_ENDPOINT}\",\"port\":5671,\"protocol\":\"amqps\",\"url\":\"${MQ_URL}\"}"
```

**Note:** Replace `YOUR_PASSWORD` with actual password from Terraform variables or Secrets Manager.

## Environment Variables Per Environment

| Variable | Local | Dev | Prod |
|----------|-------|-----|------|
| NODE_ENV | development | development | production |
| DB_HOST | postgres | swiftpay-postgres.{region}.rds.amazonaws.com | swiftpay-postgres.{region}.rds.amazonaws.com |
| REDIS_URL | redis://redis:6379 | redis://swiftpay-redis.{region}.cache.amazonaws.com:6379 | redis://swiftpay-redis.{region}.cache.amazonaws.com:6379 |
| RABBITMQ_URL | amqp://swiftpay:swiftpay123@rabbitmq:5672 | amqp://swiftpay:${SECRET}@swiftpay-mq.{region}.amazonaws.com:5671 | amqp://swiftpay:${SECRET}@swiftpay-mq.{region}.amazonaws.com:5671 |
| JWT_SECRET | your-super-secret-jwt-key-change-in-production | ${AWS_SECRETS_MANAGER} | ${AWS_SECRETS_MANAGER} |
| CORS_ORIGIN | * | https://dev.swiftpay.com | https://swiftpay.com |

**Kubernetes:** Environment variables set via ConfigMaps and Secrets (see `k8s/configmaps/app-config.yaml` and `k8s/secrets/`)

