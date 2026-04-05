# Deployment Order & Prerequisites

**New to the repo?** Read [INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md) for a full story of what we deploy, dependencies, security, and a mental model. **All docs:** [README.md](README.md).

## Quick start (targets only)

Deploy in this order using **targets** (no full `terraform apply` until the end of each phase):

| Order | Where | Command |
|-------|--------|---------|
| 0 | `terraform/` | `./bootstrap.sh --aws-only` (first time only) |
| 1 | `terraform/aws/hub-vpc` | `terraform init` → `terraform workspace new dev` → `terraform apply` |
| 2.1 | `terraform/aws/spoke-vpc-eks` | `terraform apply -target=aws_ec2_transit_gateway_vpc_attachment.eks` |
| 2.2 | same | `terraform apply -target=aws_eks_cluster.payflow` |
| 2.3 | same | `terraform apply -target=aws_eks_addon.vpc_cni` |
| 2.4 | same | `terraform apply -target=aws_eks_node_group.on_demand` |
| 2.5 | same | `terraform apply -target=aws_eks_addon.coredns` |
| 2.6 | same | `terraform apply` (remaining addons, IRSA, secrets, routes) |
| 3 | `terraform/aws/managed-services` | `terraform init` → `terraform apply` |
| 4 | `terraform/aws/bastion` | (optional) `terraform apply` |
| 5 | `k8s/overlays/eks` | `./deploy.sh` (or `IMAGE_TAG=<commit-sha> ./deploy.sh` for immutable release) |

Then follow the detailed steps below for verification and troubleshooting.

**Release tag :** To deploy a specific build, set `IMAGE_TAG` to the image tag (e.g. Git short SHA from CI): `IMAGE_TAG=abc1234 ./deploy.sh`. Default is `latest`.

## Prerequisites Checklist

Before deploying, ensure you have:

### ✅ AWS Prerequisites
- [ ] AWS CLI installed and configured (`aws configure`)
- [ ] AWS account with appropriate permissions (VPC, EKS, RDS, ElastiCache, Secrets Manager)
- [ ] `kubectl` installed
- [ ] `terraform` >= 1.5.0 installed
- [ ] Docker installed (for local testing)

### ✅ Azure Prerequisites (if deploying to AKS)
- [ ] Azure CLI installed and logged in (`az login`)
- [ ] Azure subscription with appropriate permissions
- [ ] `kubectl` configured for AKS

### ✅ Code Prerequisites
- [ ] Repository cloned
- [ ] All environment variables documented (see `.env.example` if exists)

### ✅ Terraform variables (no manual input)
Secrets are supplied via **tfvars files** (gitignored), not prompts. One-time setup:

- **spoke-vpc-eks:**  
  `cp terraform/aws/spoke-vpc-eks/terraform.tfvars.example terraform/aws/spoke-vpc-eks/terraform.tfvars`  
  Then set `db_password`, `mq_password`, `jwt_secret` in `terraform.tfvars`.
- **managed-services:**  
  `cp terraform/aws/managed-services/terraform.tfvars.example terraform/aws/managed-services/terraform.tfvars`  
  Then set `db_password`, `rabbitmq_password`.

Terraform auto-loads `terraform.tfvars` in each module directory. For CI: use `-var-file=terraform.tfvars` or `TF_VAR_db_password` (etc.).

## Deployment Order (AWS EKS)

**CRITICAL:** Deploy in this exact order using Terraform targets to avoid dependency issues.

**Terraform runs from anywhere:** The EKS endpoint is private-only. Terraform does **not** use the Kubernetes or Helm providers; it only creates AWS resources (VPC, EKS cluster, node groups, IRSA, addons, and a bootstrap EC2 instance). Cluster bootstrap (Helm addons, aws-auth) runs **inside the VPC** automatically via the bootstrap-node instance user_data. No manual kubectl from your laptop; no need to run Terraform from bastion.

### Phase 1: Bootstrap (First Time Only)

```bash
cd terraform
./bootstrap.sh --aws-only
```

**What this does:**
- Creates S3 bucket for Terraform state
- Creates DynamoDB table for state locking
- Generates `backend.tf` for spoke-vpc-eks; creates `backend.tf` for hub-vpc, managed-services, and bastion if missing (same bucket, different state keys)

**Time:** ~2 minutes

### Phase 2: Hub VPC (Networking Foundation)

```bash
cd terraform/aws/hub-vpc
terraform init
terraform workspace new dev  # or 'prod'
terraform plan
terraform apply
```

**What this creates:**
- Hub VPC
- Transit Gateway
- Public subnet (for bastion)
- Private subnet (for shared services)
- Route tables

**Time:** ~3 minutes

**Verify:**
```bash
terraform output
# Should show: hub_vpc_id, transit_gateway_id, etc.
```

### Phase 3: EKS VPC & Cluster (Use Targets!)

Ensure `terraform.tfvars` exists (copy from `terraform.tfvars.example` and set secrets) so Terraform does not prompt.

```bash
cd terraform/aws/spoke-vpc-eks
terraform init
terraform workspace select dev -or-create   # creates dev if it doesn't exist
terraform plan -out=tfplan
```

**Apply in this exact order using targets** (avoids one big apply of 90 resources). Run from `terraform/aws/spoke-vpc-eks`:

```bash
terraform apply -target=aws_ec2_transit_gateway_vpc_attachment.eks   # 3.1 net
terraform apply -target=aws_eks_cluster.payflow                        # 3.2 cluster
terraform apply -target=aws_eks_addon.vpc_cni                         # 3.3 CNI
terraform apply -target=aws_eks_node_group.on_demand                  # 3.4 nodes
terraform apply -target=aws_eks_addon.coredns                         # 3.5 coredns
terraform apply                                                       # 3.6 rest
```

| Step | Command | Creates |
|------|---------|--------|
| 3.1 | `terraform apply -target=aws_ec2_transit_gateway_vpc_attachment.eks` | VPC, subnets, NAT, TGW attachment |
| 3.2 | `terraform apply -target=aws_eks_cluster.payflow` | EKS control plane |
| 3.3 | `terraform apply -target=aws_eks_addon.vpc_cni` | VPC CNI addon |
| 3.4 | `terraform apply -target=aws_eks_node_group.on_demand` | Worker nodes |
| 3.5 | `terraform apply -target=aws_eks_addon.coredns` | CoreDNS addon |
| 3.6 | `terraform apply` | Rest: EKS addons, IRSA, Secrets Manager, bootstrap-node, WAF, Config, etc. Helm addons are installed by bootstrap-node inside VPC. |

**Confirm what exists in AWS (CLI):**
```bash
aws sts get-caller-identity
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=payflow-eks-vpc" --query 'Vpcs[].{VpcId:VpcId,CidrBlock:CidrBlock}' --output table
aws eks list-clusters --query 'clusters' --output table
aws eks describe-cluster --name payflow-eks-cluster --query 'cluster.{status:status,endpoint:endpoint}' --output table
aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
aws ec2 describe-transit-gateway-vpc-attachments --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=payflow-eks-vpc --query 'Vpcs[0].VpcId' --output text)" --query 'TransitGatewayVpcAttachments[].State' --output text
```

**Accessing EKS (private endpoint):** The EKS API is private. All `kubectl` commands must be run from inside the VPC. Options: (1) SSM to the bootstrap instance (before it self-terminates) or (2) bastion (Phase 5) or VPN.

**Deployment flow (refactored):**
1. **`terraform apply`** (from anywhere) — creates infra + bootstrap EC2. Bootstrap runs user_data: installs kubectl/helm, update-kubeconfig, installs aws-load-balancer-controller, external-secrets, metrics-server, cluster-autoscaler, applies aws-auth; then optionally terminates itself.
2. **Optional debugging:** `aws ssm start-session --target <bootstrap-instance-id>` (if instance still running) to inspect `/var/log/bootstrap.log` or run kubectl.

**One-time setup — run from inside VPC (bastion or SSM to bootstrap):**
```bash
# Get bastion IP (from terraform/aws/bastion: terraform output)
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# On bastion: configure kubectl (once)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
```

**Optional — SSH config (skip if already added):** Add to `~/.ssh/config` so you can run `ssh payflow-bastion`:
```sshconfig
# Key-based SSH
Host payflow-bastion
  HostName <bastion-public-ip>
  User ec2-user
  IdentityFile ~/.ssh/payflow-bastion-key.pem
```
If bastion has SSM and you prefer not to open port 22:
```sshconfig
Host payflow-bastion
  HostName <bastion-instance-id>
  User ec2-user
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```

---

#### Step 3.1: Networking First
```bash
terraform apply -target=aws_ec2_transit_gateway_vpc_attachment.eks
```
**Why:** This target pulls in VPC, subnets, NAT Gateway, route tables, and TGW attachment (all in `main.tf`). Must exist before cluster.

**Time:** ~5 minutes

#### Step 3.2: EKS Cluster (without nodes)
```bash
terraform apply -target=aws_eks_cluster.payflow
```
**Why:** Cluster API must exist before addons and nodes.

**Time:** ~15 minutes

#### Step 3.3: VPC CNI Addon (Critical!)
```bash
terraform apply -target=aws_eks_addon.vpc_cni
```
**Why:** Pods need IP addresses. CNI must be installed before nodes join.

**Time:** ~2 minutes

**Verify CNI is ready:** *(Run from bastion; see "Accessing EKS" above.)*
```bash
kubectl get pods -n kube-system -l k8s-app=aws-node
# Or: kubectl get pods -n kube-system | grep aws-node
# Wait until all pods are Running (one per node)
```

#### Step 3.4: On-Demand Node Group
```bash
terraform apply -target=aws_eks_node_group.on_demand
```
**Why:** Stateful services (wallet, transaction) need stable nodes.

**Time:** ~10 minutes

**Verify nodes are ready:** *(Run from bastion; see "Accessing EKS" above.)*
```bash
kubectl get nodes -l workload-type=stateful
# Wait until all nodes are Ready
```

#### Step 3.5: CoreDNS Addon
```bash
terraform apply -target=aws_eks_addon.coredns
```
**Why:** DNS resolution needed for services. Requires nodes to be ready.

**Time:** ~2 minutes

#### Step 3.6: Everything Else
```bash
terraform apply
```
**What this applies:**
- Remaining addons (kube-proxy, etc.)
- IRSA roles
- Secrets Manager secrets
- Route from Hub to EKS

**Time:** ~5 minutes

**Verify cluster is ready:** *(Run from bastion; see "Accessing EKS" above.)*
```bash
kubectl cluster-info
kubectl get nodes
# Should show all nodes Ready
```

### Phase 4: Managed Services (RDS, ElastiCache, MQ)

Ensure `terraform.tfvars` exists here (copy from `terraform.tfvars.example`; set `db_password`, `rabbitmq_password`).

```bash
cd terraform/aws/managed-services
terraform init
terraform workspace select dev -or-create
# Set tfstate_bucket to your state bucket (same as EKS) to auto-wire EKS SG from spoke state; else pass eks_node_security_group_id
terraform plan -out=tfplan
terraform apply
```

**CI (e.g. GitHub Actions):** Set `TF_VAR_tfstate_bucket` to your state bucket and use the same workspace as Spoke so EKS SG is wired from state; no need to pass the SG ID.

**What this creates:**
- RDS PostgreSQL (takes ~20 minutes)
- ElastiCache Redis (takes ~10 minutes)
- Amazon MQ RabbitMQ (takes ~15 minutes)
- Secrets in AWS Secrets Manager

**Time:** ~20-30 minutes (RDS is the bottleneck)

**Verify:**
```bash
terraform output
# Should show: rds_endpoint, elasticache_endpoint, mq_endpoint
```

**Note:** The `null_resource` in `secrets-manager.tf` automatically updates Secrets Manager with RDS/MQ endpoints after they're created.

### Phase 5: Bastion (Optional but Recommended)

```bash
cd terraform/aws/bastion
terraform init
terraform workspace select dev
terraform apply
```

**What this creates:**
- EC2 instance in Hub public subnet
- Security group allowing SSH from authorized IPs
- Route from bastion to EKS (via Transit Gateway)

**Time:** ~3 minutes

### Phase 6: Application Deployment

```bash
cd k8s/overlays/eks
./deploy.sh
```

**What the script does:**
1. Verifies Terraform backend files exist
2. Gets AWS Account ID
3. Replaces `<ACCOUNT_ID>` in `kustomization.yaml`
4. Sets environment (dev/prod) in `eks-external-secrets.yaml`
5. Updates RDS/Redis endpoints in `db-config-patch.yaml` from Terraform
6. Validates Kustomize build (full + phase1-migrations)
7. Prompts for deployment confirmation
8. **Phase 1 (migrations):** Applies only namespace, config, secrets, and the `db-migration-job`; waits for the job to complete (timeout 10m). Migrations run **before** any new app version serves traffic to avoid race conditions.
9. **Phase 2 (app):** Applies the full manifest (deployments, services, policies, etc.)

**Why two-phase:** Migrations are a separate step, not part of app startup. Running them before the new app version goes live prevents multiple pods from migrating the database at once and ensures the schema is ready when new pods receive traffic.

**Time:** ~2–5 minutes (longer if migrations take time)

**Verify deployment:** *(Run from bastion; see "Accessing EKS" in Phase 3.)*
```bash
kubectl get pods -n payflow
kubectl get svc -n payflow
kubectl logs -n payflow deployment/api-gateway
```

## Deployment Order (Azure AKS)

### Phase 1: Bootstrap

```bash
cd terraform
./bootstrap.sh --azure-only
```

### Phase 2: Hub VNet

```bash
cd terraform/azure/hub-vnet
terraform init
terraform workspace new dev
terraform apply
```

### Phase 3: AKS Cluster

```bash
cd terraform/azure/spoke-vnet-aks
terraform init
terraform workspace select dev
terraform apply
```

**Time:** ~20 minutes

### Phase 4: Managed Services

```bash
cd terraform/azure/managed-services
terraform init
terraform workspace select dev
terraform apply
```

### Phase 5: Application Deployment

**Important:** For AKS, you must use self-hosted RabbitMQ (see `docs/AKS-AMQP-INCOMPATIBILITY.md`):

1. Update `k8s/overlays/aks/kustomization.yaml`:
```yaml
resources:
  - ../../base
  - ../../infrastructure/rabbitmq.yaml  # Add this
  - aks-external-secrets.yaml
```

2. Update `k8s/overlays/aks/db-config-patch.yaml`:
```yaml
RABBITMQ_URL: "amqp://rabbitmq:5672"  # Local service, not Service Bus
```

3. Deploy (two-phase: migrations first, then app):
```bash
cd k8s/overlays/aks
./aks-deploy.sh
```
The script runs the database migration job and waits for it to complete before deploying the application, so the new app version only serves traffic after migrations finish.

## Common Issues & Solutions

### Issue: "Error: Resource depends on resource that doesn't exist"
**Solution:** You skipped a target. Go back and apply the missing resource.

### Issue: "Error: VPC CNI pods not starting"
**Solution:** Wait for EKS cluster to be fully ready (all control plane components), then apply CNI addon.

### Issue: "Error: Nodes not joining cluster" or node group stuck "Still creating..." (15+ min)
**Cause:** Nodes need to be allowed by the cluster (aws-auth ConfigMap or EKS Access Entries). This repo uses both: cluster has `access_config.authentication_mode = "API_AND_CONFIG_MAP"` and an EKS access entry for the node IAM role so nodes can join without waiting for the ConfigMap.
**Solution:** If the node group is stuck, run `terraform apply` again so the cluster gets the access config and access entry (if not already applied). Then the node group should complete. From bastion you can verify: `kubectl get pods -n kube-system -l k8s-app=aws-node` and `kubectl get nodes`.

### Issue: "Instance cannot be destroyed" when applying (plan wants to destroy EKS cluster)
**Cause:** Terraform treats adding `access_config` to an existing cluster as requiring replacement (destroy+create). The cluster has `lifecycle.prevent_destroy`, so the plan fails.
**Solution:**  
1. **One-time:** Enable Access Entries on the cluster via AWS CLI (no cluster replace):
   ```bash
   aws eks update-cluster-config \
     --name payflow-eks-cluster \
     --access-config authenticationMode=API_AND_CONFIG_MAP \
     --region us-east-1
   ```
   Wait until the cluster status is ACTIVE again (EKS console or `aws eks describe-cluster --name payflow-eks-cluster --query 'cluster.status'`).  
2. **Terraform:** We set `ignore_changes = [access_config]` on the cluster so Terraform won’t try to replace it. Run `terraform apply` again; the cluster won’t be in the plan, and the access entry + node group will apply.

### Issue: "ResourceInUseException" (409) on EKS Access Entry
**Cause:** The access entry for the node role already exists in AWS (e.g. EKS created it when the node group joined).
**Solution:** Import it so Terraform manages it (replace ACCOUNT_ID with your AWS account ID):
```bash
terraform import aws_eks_access_entry.node_role payflow-eks-cluster:arn:aws:iam::ACCOUNT_ID:role/payflow-eks-node-role
```
Then run `terraform apply` again.

### Issue: "ConfigMap aws-auth" TLS handshake timeout
**Cause:** Terraform cannot reach the private EKS API (e.g. you ran Terraform from outside the VPC).
**Solution:** Run Terraform from the bastion or via SSM (inside the VPC) so it can reach the cluster. With that, `manage_aws_auth_configmap = true` (default) works. If you must run Terraform from outside the VPC, set `manage_aws_auth_configmap = false` and apply the aws-auth ConfigMap later from the bastion with kubectl.

### Issue: "NodeGroup already exists" (409) on on-demand node group
**Cause:** The node group exists in AWS but Terraform state doesn’t have it (e.g. a previous apply partially succeeded).
**Solution:** Import it: `terraform import aws_eks_node_group.on_demand payflow-eks-cluster:payflow-on-demand`. If the node group is in "Create failed" state in the EKS console, delete it in the console first, then run `terraform apply` so Terraform creates it again.

### Issue: "Error: ImagePullBackOff"
**Solution:** Replace `<ACCOUNT_ID>` in `k8s/overlays/eks/kustomization.yaml` or run `./deploy.sh`.

### Issue: "Error: Cannot connect to RDS"
**Solution:** 
1. Verify RDS endpoint from Terraform output
2. Check security group allows traffic from EKS nodes
3. Verify Secrets Manager has correct credentials

## Rollback Procedures

### Rollback Application
*(Run from bastion; see "Accessing EKS" in Phase 3.)*
```bash
kubectl rollout undo deployment/[service-name] -n payflow
```

### Rollback Infrastructure
```bash
# Restore previous Terraform state from S3
aws s3 cp s3://[bucket]/env:/dev/eks/terraform.tfstate \
  terraform.tfstate --version-id [version-id]
```

### Rollback Database
```bash
# Restore from snapshot (if created before migration)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier payflow-postgres-restored \
  --db-snapshot-identifier pre-migration-[date]
```

## Time Estimates

| Phase | Time | Notes |
|-------|------|-------|
| Bootstrap | 2 min | One-time setup |
| Hub VPC | 3 min | Quick |
| EKS VPC & Cluster | 40-50 min | Use targets to parallelize |
| Managed Services | 20-30 min | RDS is slowest |
| Bastion | 3 min | Optional |
| Application | 2 min | Fast with script |
| **Total** | **~70-90 min** | First deployment |

Subsequent deployments are faster (infrastructure already exists).

