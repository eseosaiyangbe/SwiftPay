# SwiftPay Infrastructure — Onboarding for New Engineers

> **Canonical first read for AWS/EKS story + order.** Terraform command tables and targets: [DEPLOYMENT-ORDER.md](DEPLOYMENT-ORDER.md). Long ops guide (SSM, ECR): [INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md](INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md). **All docs:** [README.md](README.md).

This document explains the **entire infrastructure** as a clear, step-by-step story so a new teammate can understand what we deploy, in what order, and how it all fits together.

---

## 1. High-Level Overview: What Does This Infrastructure Deploy?

We run **SwiftPay** (a wallet/transaction app) on **AWS** with this shape:

- **Hub-and-spoke networking:** A central **Hub VPC** with a **Transit Gateway** and a **Spoke VPC** where the **EKS (Kubernetes) cluster** lives. The bastion host sits in the Hub for secure access.
- **EKS cluster:** Kubernetes runs our app (API Gateway, Auth, Wallet, Transaction, Notification, Frontend). Nodes are in **private subnets**; they reach the internet via **NAT Gateway**.
- **Managed data services:** **RDS (PostgreSQL)**, **ElastiCache (Redis)**, and **Amazon MQ (RabbitMQ)** live in the **same VPC as EKS** (the Spoke VPC) but are created by a **separate Terraform module** (managed-services). Only EKS nodes are allowed to talk to them (security groups).
- **Secrets:** DB and MQ passwords live in **AWS Secrets Manager**. The EKS cluster uses **External Secrets Operator** to sync those into Kubernetes Secrets so pods never see raw AWS API keys.
- **Application deploy:** After Terraform, we deploy the app with **Kustomize** and a two-phase script: **migrations run first** (one Job), then the **full app** (see `k8s/overlays/eks/deploy.sh`).

So in one sentence: **Terraform builds the network (Hub + Spoke), the EKS cluster, RDS/Redis/MQ, and secrets; then we deploy the app onto EKS with migrations before app.**

**Figures:** The pipeline and secrets diagrams below match the story in this section; all `docs/assets` images are also collected in [architecture.md](architecture.md#infrastructure).

![EKS VPC hub-and-spoke integration pipeline](assets/EKS%20VPC%20Integration%20Pipeline-2026-03-30-135753.png)

---

## 2. Terraform Execution Order (Step by Step)

You **must** run Terraform in this order. Later modules depend on earlier ones (by outputs → variables or by data-source lookups).

| Step | Directory | What you run | Why this order |
|------|-----------|--------------|-----------------|
| **0** | `terraform/` | `./bootstrap.sh --aws-only` | One-time: creates S3 bucket + DynamoDB for Terraform state and lock; writes `backend.tf` into each module so state is remote. |
| **1** | `terraform/aws/hub-vpc` | `terraform init` → `workspace new dev` → `terraform apply` | Creates Hub VPC, subnets, Transit Gateway, and route so the Hub can eventually reach the Spoke. No other module depends on Hub **in Terraform**, but the Spoke **looks up** Hub by name (data sources) and **writes a route** on the Hub’s route table. So Hub must exist first. |
| **2** | `terraform/aws/spoke-vpc-eks` | Apply in **targets** (see below), then full `terraform apply` — **run Terraform from bastion or SSM** (inside the VPC) so the private EKS API is never exposed | Creates Spoke VPC, EKS cluster, node groups, addons (VPC CNI, CoreDNS, etc.), IRSA roles, Secrets Manager, ECR, optional WAF/GuardDuty. **Output:** `eks_cluster_security_group_id` — you pass this to managed-services. |
| **3** | `terraform/aws/managed-services` | `terraform init` → `terraform apply` with **variable** `eks_node_security_group_id` set to the value from step 2 | Creates RDS, ElastiCache, Amazon MQ in the EKS VPC. Their security groups allow traffic **only** from that EKS security group. You must pass the SG ID manually (e.g. `-var="eks_node_security_group_id=sg-xxx"`) or via `.tfvars` / CI. |
| **4** | `terraform/aws/bastion` | (Optional) `terraform apply` | Puts a small EC2 in the Hub’s public subnet so you can SSH in and run `kubectl` (or tunnel) to the EKS API. |

**Spoke (step 2) — recommended target order** (so Terraform doesn’t try to create everything in one go and hit ordering issues):

1. `terraform apply -target=aws_ec2_transit_gateway_vpc_attachment.eks`  
   → Brings in VPC, subnets, NAT, route tables, TGW attachment.
2. `terraform apply -target=aws_eks_cluster.swiftpay`  
   → Cluster control plane only.
3. `terraform apply -target=aws_eks_addon.vpc_cni`  
   → Pods need CNI to get IPs.
4. `terraform apply -target=aws_eks_node_group.on_demand` then `-target=aws_eks_node_group.spot`  
   → Worker nodes.
5. `terraform apply -target=aws_eks_addon.coredns`  
   → In-cluster DNS.
6. `terraform apply`  
   → Everything else (other addons, IRSA, Secrets Manager, Helm charts like External Secrets, ALB controller, etc.).

Full target list and rationale are in `docs/DEPLOYMENT-ORDER.md`.

**Bastion → kubectl verification (after Terraform):** If you use the bastion to run `kubectl`, ensure: (1) Hub **public** route table has `10.10.0.0/16 → TGW`, (2) Hub TGW attachment includes **both** public and private subnets (same AZs as bastion and Spoke), (3) Spoke **public** route tables have `10.0.0.0/16 → TGW` (return path for EKS API ENIs in public subnets), (4) Bastion IAM role is in EKS access entries with cluster-admin (or equivalent). See **§10 Troubleshooting** if `kubectl` times out.

**Bastion via SSM — use instance role for kubectl:** In an SSM session the shell may not use the bastion’s IAM instance profile for AWS CLI; if you see “the server has asked for the client to provide credentials”, force the instance role and refresh kubeconfig:

```bash
export AWS_REGION=us-east-1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity   # should show swiftpay-bastion-role
aws eks update-kubeconfig --region $AWS_REGION --name swiftpay-eks-cluster
kubectl get nodes
```

**Single node `SchedulingDisabled` (cordoned):** After a node group replace or scale-up, one node may be Ready but cordoned while others are still joining. Check with `kubectl get nodes -o wide` and `aws eks describe-nodegroup --cluster-name swiftpay-eks-cluster --nodegroup-name swiftpay-on-demand --region us-east-1 --query 'nodegroup.scalingConfig'`. If desired size is 3, wait a few minutes for the other nodes to become Ready and uncordoned.

### How to destroy (reverse of apply order)

Destroy in **reverse** order so dependencies are removed last. Use the same Terraform workspace (e.g. `dev`) in each module.

| Step | Directory | What you run |
|------|-----------|--------------|
| 1 | `terraform/aws/bastion` | `terraform destroy` |
| 2 | `terraform/aws/managed-services` | `terraform destroy` (same `-var` or tfvars if you used them for apply) |
| 3 | `terraform/aws/spoke-vpc-eks` | `terraform destroy` (run from a machine that can reach the EKS API, or use SSM; cluster must be deleted before VPC) |
| 4 | `terraform/aws/hub-vpc` | `terraform destroy` |
| 5 | `terraform/` (bootstrap) | Optional: empty the S3 state bucket and destroy the bucket + DynamoDB table if you want to remove everything. Often the state backend is kept for reuse. |

**Notes:**

- **Managed-services:** If you applied with `-var="eks_node_security_group_id=..."` you don’t need it for destroy, but any other variables (e.g. region, environment) should match.
- **Spoke-vpc-eks:** EKS and node groups can take several minutes to delete. If destroy hangs, check for leftover ENIs, load balancers, or PVCs; drain nodes first if you had workloads.
- **Hub-vpc:** Destroy only after Spoke is gone, since Spoke creates a route on the Hub’s route table.

---

## 3. Dependencies (Explicit and Implicit)

### 3.1 Explicit `depends_on` (in code)

- **Hub:** `aws_route.hub_public_to_eks` depends on `aws_ec2_transit_gateway_vpc_attachment.hub` so the route to the Spoke exists only after the Hub is attached to the TGW.
- **Spoke:**  
  - NAT Gateway depends on Internet Gateway.  
  - EKS cluster depends on cluster IAM role and (often) a `time_sleep` after IAM so AWS can propagate.  
  - **EKS access entry** (node role) depends on cluster; cluster uses `access_config.authentication_mode = "API_AND_CONFIG_MAP"` so nodes can join via Access Entry (no chicken-and-egg with aws-auth ConfigMap).  
  - **aws-auth ConfigMap** depends only on cluster (for mapUsers/admin); nodes do **not** need it to join because the access entry allows the node IAM role.  
  - VPC CNI addon depends on cluster + `wait_for_irsa`.  
  - Node groups depend on cluster + VPC CNI (nodes join via EKS Access Entry, not aws-auth).  
  - CoreDNS/kube-proxy addons depend on node groups.  
  - Helm releases (ALB controller, External Secrets, etc.) depend on node groups and their IRSA roles.

So: **networking → IAM → cluster → access entry + (optional) aws-auth → VPC CNI → nodes → more addons → Helm.**

### 3.2 Implicit / cross-stack dependencies

- **Spoke → Hub:** Spoke uses **data sources** to find Hub VPC and Transit Gateway by **name tags** (`swiftpay-hub-vpc`, `swiftpay-hub-tgw`). It then creates `aws_route.hub_to_eks` on the **Hub’s private route table** (also looked up by data). So Hub must be applied first; there is **no** Terraform resource dependency, only “you ran Hub first.”
- **Managed-services → Spoke:** Managed-services does **not** use Terraform remote state in the snippets we have. You pass **`eks_node_security_group_id`** (from Spoke’s output `eks_cluster_security_group_id`) as a **variable** when you apply managed-services. So operationally: Spoke first, then managed-services with that variable.
- **RDS/Redis/MQ:** They use **data sources** to find the EKS VPC and private subnets by tags (`swiftpay-eks-vpc`, `swiftpay-eks-private-subnet-*`). So Spoke VPC and subnets must exist before managed-services apply.

**Summary:** Hub first → Spoke (with targets) → managed-services (with EKS SG ID). Bastion anytime after Hub.

---

## 4. Major Modules and How They Connect

| Module | Path | Creates | Connects to |
|--------|------|---------|------------|
| **Bootstrap** | `terraform/bootstrap.sh` | S3 bucket, DynamoDB table, `backend.tf` in each module | Used by every Terraform run (state + lock). |
| **Hub VPC** | `terraform/aws/hub-vpc` | VPC, public/private subnets, IGW, route tables, Transit Gateway, TGW attachment, route from Hub to Spoke CIDR via TGW | Spoke uses **data** to find Hub and writes `aws_route.hub_to_eks` on Hub’s route table. Bastion uses Hub VPC/subnet (data). |
| **Spoke VPC EKS** | `terraform/aws/spoke-vpc-eks` | Spoke VPC, public/private subnets, NAT GW, EKS cluster, node groups, VPC CNI/CoreDNS/EBS CSI, IRSA roles, Secrets Manager secrets, ECR repos, optional Route53/ACM/WAF/GuardDuty/CloudTrail/Config, Helm (ALB, External DNS, External Secrets, etc.) | Reads Hub via data; outputs `eks_cluster_security_group_id`. |
| **Managed services** | `terraform/aws/managed-services` | RDS (PostgreSQL), ElastiCache (Redis), Amazon MQ (RabbitMQ), SGs for each | **Variable** `eks_node_security_group_id` (from Spoke). Looks up EKS VPC/subnets by tags. RDS/Redis/MQ live in **same VPC** as EKS. |
| **Bastion** | `terraform/aws/bastion` | EC2 instance, SG (SSH from allowed IPs, egress to 10.0.0.0/8:443 and DNS) | Uses Hub VPC and public subnet (data). Run Terraform for spoke-vpc-eks and `kubectl` from here (or via SSM) so EKS stays private. |

**Data flow (Terraform):**  
Hub and Spoke are **not** in the same state file. Spoke finds Hub by **name**. Managed-services finds EKS VPC by **tags** and receives EKS SG ID as a **variable**. So the “glue” is: naming/tags and you passing the SG ID (CLI, tfvars, or CI).

---

## 5. Network Traffic Flow (Internet → Ingress → Services → Database)

- **User → app (HTTPS)**  
  - User hits a domain (e.g. Route53 → ALB).  
  - **ALB** (created by AWS Load Balancer Controller from Kubernetes Ingress) is in **EKS public subnets**.  
  - ALB forwards to **Kubernetes Services** (e.g. api-gateway, frontend) in the **swiftpay** namespace.  
  - Pods run on **private subnets**; they pull images from ECR and talk to RDS/Redis/MQ inside the same VPC.

- **EKS nodes (private subnet)**  
  - Outbound internet (e.g. ECR, Secrets Manager) goes through **NAT Gateway** in the public subnet.  
  - To RDS/Redis/MQ: traffic stays in-VPC; **security groups** allow only the EKS cluster security group to ports 5432, 6379, 5671, etc.

- **Bastion**  
  - You SSH to the bastion (in Hub public subnet). From there you can reach EKS API (e.g. over 443) via the **Hub → TGW → Spoke** route and use `kubectl`.

So: **Internet → ALB (public) → K8s Services → Pods (private) → RDS/Redis/MQ (private, SG-restricted)**. No database or message queue is exposed to the internet.

---

## 6. Security Components

- **Security groups (NSG-like)**  
  - **RDS:** Ingress TCP 5432 only from `eks_node_security_group_id`.  
  - **ElastiCache:** Ingress TCP 6379 only from EKS nodes.  
  - **Amazon MQ:** Ingress 5671 (AMQP) and 15671 (console) only from EKS nodes.  
  - **Bastion:** Ingress SSH from `var.authorized_ssh_cidrs`; egress 443 to 10.0.0.0/8 and DNS.  
  - EKS uses the **managed cluster security group**; we pass that as “node” SG to managed-services so only the cluster can reach DB/Redis/MQ.

- **IAM**  
  - **EKS cluster role:** Used by the control plane (e.g. EKS managed policy).  
  - **EKS node role:** Used by worker nodes (EKS worker, CNI, ECR read, SSM).  
  - **IRSA (pod-level):** VPC CNI, ALB controller, External DNS, EBS CSI, Cluster Autoscaler, **External Secrets** — each has an IAM role tied to a Kubernetes service account via OIDC. Pods that need AWS APIs use these; e.g. External Secrets pulls from Secrets Manager.  
  - **Bastion:** IAM role for the instance (e.g. EKS DescribeCluster for `kubectl`).  
  - **Flow logs / Config:** Dedicated roles for VPC flow logs and AWS Config.

- **Secrets**  
  - **AWS Secrets Manager:** RDS, RabbitMQ, Redis, and app secrets. Encrypted with a **KMS key**.  
  - **External Secrets Operator (in EKS):** Syncs Secrets Manager → Kubernetes Secrets so pods get DB/MQ URLs and passwords without storing them in Git or in plain Terraform.

![EKS cluster and secrets integration](assets/AWS%20EKS%20Cluster%20Secrets-2026-03-30-104747.png)

- **Optional (in Spoke module)**  
  - **WAF** (if enabled) in front of ALB.  
  - **GuardDuty**, **CloudTrail**, **AWS Config**, **Security Hub** for monitoring and compliance.

---

## 7. Risks, Tight Coupling, and Improvements

- **EKS SG wiring (fixed):** Managed-services can read the EKS security group from Spoke state automatically. Set `tfstate_bucket` to your state bucket (same as EKS module) and use the same Terraform workspace; then you don’t need to pass `eks_node_security_group_id`. You can still pass it to override.
- **Hub/Spoke (fixed):** Spoke can read Hub from state: set `hub_tfstate_bucket` (same as Hub module, same workspace) so Hub VPC/TGW/route table come from state instead of tag lookups. If someone renames or duplicates Hub, Spoke can point at the wrong VPC. **Assumption:** One Hub per account/region and we don’t change those tags.
- **Secrets in Terraform:** Initial RDS/MQ passwords can be in Terraform (variables or even in Secrets Manager resource). We use `ignore_changes` on secret value so rotation doesn’t get overwritten. In production, set and rotate RDS/MQ passwords outside Terraform (e.g. Secrets Manager console or CI); avoid storing initial secrets in code.
- **Single region/AZ assumptions:** Some resources use the first AZ or a fixed list. Multi-region or strict multi-AZ failover would need a review.
- **Bastion egress (fixed):** Egress to the EKS API is limited to the Spoke VPC CIDR via `spoke_vpc_cidr` (default `10.10.0.0/16`) instead of `10.0.0.0/8`.
- **Bastion → kubectl path (fixed):** Hub public route table has `10.10.0.0/16 → TGW`; Hub TGW attachment includes both public and private subnets (TGW needs a subnet in the same AZ as the traffic source); Spoke public route tables have `10.0.0.0/16 → TGW` for return path; bastion role is in EKS access entries. See **§10 Troubleshooting** for the full postmortem and steps we took.
- **Two-phase app deploy:** Migrations run before app; if the migration job fails, the script exits and the rest of the app is not applied. That’s desired; just be aware that fixing a failed migration is a manual step before re-running deploy.

---

## 8. Assumptions When Something Is Unclear

- **State:** Hub, managed-services, and bastion may use the same S3 backend pattern as Spoke; the exact keys are defined in each module’s `backend.tf` (often written by bootstrap).  
- **Workspaces:** We use Terraform workspaces (e.g. `dev` / `prod`) for environment separation; workspace can affect state key and some variables.  
- **Domain/ingress:** Production likely uses Route53 + ACM (in Spoke) and ALB; the exact hostname and cert are environment-specific.  
- **Secrets Manager updates:** A `null_resource` or similar may update secret versions with RDS/MQ endpoints after creation; see `managed-services` and `secrets-manager.tf` for any post-create updates.

---

## 9. Mental Model Summary

- **Bootstrap** = “Where does Terraform store state?” (S3 + DynamoDB).  
- **Hub** = Central network with a Transit Gateway; the Bastion lives here; one route points to the Spoke.  
- **Spoke** = The EKS VPC and the cluster itself: networking, nodes, addons, IRSA, Secrets Manager, ECR, and optional security/observability. It **looks up** the Hub and **writes one route** on the Hub so traffic can reach EKS.  
- **Managed-services** = RDS, Redis, MQ in the **same VPC** as EKS, with security groups that **only** allow the EKS cluster. You must give it the EKS security group ID when you apply.  
- **Bastion** = Optional jump host in the Hub to run `kubectl` or SSH tunnels to EKS.  
- **App deploy** = After Terraform, we build one manifest with Kustomize and run a two-phase deploy: **Phase 1** applies only migration job + deps and waits for the job to complete; **Phase 2** applies the full app so migrations always run before new pods serve traffic.

So: **Network (Hub + Spoke) → Kubernetes (EKS) → Data (RDS, Redis, MQ) and Secrets (Secrets Manager → External Secrets → K8s).** Everything is in one AWS account/region; the only cross-stack “dependency” you must remember is **passing the EKS security group ID into managed-services** when you apply it.

---

## 10. Troubleshooting: kubectl get nodes — Postmortem

**SwiftPay EKS | Hub-Spoke Architecture | February 26, 2026**

### The Symptom

From the bastion (via SSM), every `kubectl` command timed out:

```
dial tcp 10.10.10.25:443: i/o timeout
dial tcp 10.10.1.30:443: i/o timeout
```

### The Architecture (what should happen)

```
Bastion (10.0.1.97)          Transit Gateway          EKS API (10.10.10.25 / 10.10.1.30)
  Hub VPC 10.0.0.0/16   ──►  tgw-07fab25c49fed2786 ──►  Spoke VPC 10.10.0.0/16
```

For this to work, 4 things must all be true simultaneously:

1. Hub public route table has `10.10.0.0/16 → TGW`
2. Hub TGW attachment includes the bastion's subnet (same AZ)
3. Spoke TGW attachment includes the EKS endpoint subnets
4. Spoke public route table has `10.0.0.0/16 → TGW` (return path)

All 4 were broken or missing. We found them one by one.

### Steps we took (summary)

1. **Spoke public route tables** — In `terraform/aws/spoke-vpc-eks/main.tf`, added route `10.0.0.0/16 → TGW` to every EKS public route table so return traffic from EKS API (including ENIs in public subnets) can reach the Hub. Applied spoke-vpc-eks.
2. **Bastion EKS access** — From a machine with AWS CLI: `aws eks create-access-entry` and `aws eks associate-access-policy` for `swiftpay-bastion-role` with `AmazonEKSClusterAdminPolicy`. Then added `aws_eks_access_entry.bastion` and `aws_eks_access_policy_association.bastion_admin` in `terraform/aws/spoke-vpc-eks/aws-auth.tf` and applied spoke-vpc-eks so it’s permanent.
3. **Hub TGW attachment** — In `terraform/aws/hub-vpc/main.tf`, changed the hub TGW attachment to include both subnets: `subnet_ids = [aws_subnet.hub_public.id, aws_subnet.hub_private.id]`. Applied hub-vpc so the bastion’s AZ (public subnet) is attached to the TGW.
4. **Hub public route (immediate unblock)** — Manually added the missing route: `aws ec2 create-route --route-table-id rtb-09c0e0248abb9757e --destination-cidr-block 10.10.0.0/16 --transit-gateway-id tgw-07fab25c49fed2786`. Then ran `terraform apply` on hub-vpc so `aws_route.hub_public_to_eks` is in state and the route stays.

After these four steps, `kubectl get nodes` from the bastion (via SSM) succeeded.

### The 4 Root Causes (in order found)

#### Bug 1 — EKS endpoint ENI in a public subnet with no return route

**What happened:** EKS placed one of its two endpoint ENIs in a public subnet (`subnet-0238320ced17fc908`, `10.10.10.0/24`). That subnet's route table had no route back to the hub VPC (`10.0.0.0/16`). Return packets from EKS had nowhere to go and were dropped.

**How we found it:** Checked which subnets the EKS ENIs were in. One was named `swiftpay-eks-public-subnet-1` — public, not private. Its route table had only `local` and `0.0.0.0/0 → IGW`. No TGW route.

**Fix:** Added `10.0.0.0/16 → TGW` to all EKS public subnet route tables in `terraform/aws/spoke-vpc-eks/main.tf`:

```hcl
resource "aws_route_table" "eks_public" {
  route {
    cidr_block         = var.hub_vpc_cidr      # 10.0.0.0/16
    transit_gateway_id = local.transit_gateway_id
  }
}
```

#### Bug 2 — Bastion role not in EKS access entries

**What happened:** `swiftpay-bastion-role` was not in the EKS access entries list. EKS accepted the TCP connection, checked the token, found no binding, and closed the connection — which looked like a timeout from the client.

**How we found it:**

```bash
aws eks list-access-entries --cluster-name swiftpay-eks-cluster
# bastion role was not listed
```

**Fix:** Added access entry and cluster-admin policy from local machine:

```bash
aws eks create-access-entry \
  --cluster-name swiftpay-eks-cluster \
  --principal-arn arn:aws:iam::334091769766:role/swiftpay-bastion-role

aws eks associate-access-policy \
  --cluster-name swiftpay-eks-cluster \
  --principal-arn arn:aws:iam::334091769766:role/swiftpay-bastion-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

**Lock in Terraform** (`terraform/aws/spoke-vpc-eks/aws-auth.tf`):

```hcl
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.swiftpay.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/swiftpay-bastion-role"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = aws_eks_cluster.swiftpay.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/swiftpay-bastion-role"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.bastion]
}
```

#### Bug 3 — Hub TGW attachment missing the bastion's AZ

**What happened:** The hub VPC TGW attachment only included the private subnet (`subnet-0d221cc6d9d236eb9`, `us-east-1b`). The bastion is in the public subnet (`subnet-098eb11834bf2ff1a`, `us-east-1a`). AWS TGW requires a subnet attachment in the same AZ as the traffic source. Bastion traffic hit the TGW but was dropped because no attachment existed in `us-east-1a`.

**How we found it:**

```bash
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=vpc-id,Values=vpc-06d7d8715253e07af"
# showed only 1 subnet: subnet-0d221cc6d9d236eb9
```

**Fix:** Updated hub TGW attachment in `terraform/aws/hub-vpc/main.tf` to include both subnets, then applied hub-vpc:

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  subnet_ids = [aws_subnet.hub_public.id, aws_subnet.hub_private.id]
  ...
}
```

#### Bug 4 — Hub public route table missing the spoke CIDR route (the actual blocker)

**What happened:** The hub public route table (`rtb-09c0e0248abb9757e`) only had:

- `10.0.0.0/16 → local`
- `0.0.0.0/0 → IGW`

The route `10.10.0.0/16 → TGW` was missing in AWS even though it existed in Terraform code. This meant packets from the bastion destined for EKS were being sent out to the internet via IGW instead of through the TGW. They never arrived.

**How we found it:**

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-098eb11834bf2ff1a" \
  --query "RouteTables[0].Routes[].DestinationCidrBlock"
# returned: ["10.0.0.0/16", "0.0.0.0/0"]
# 10.10.0.0/16 was missing
```

**Fix:** Added the route manually to unblock immediately:

```bash
aws ec2 create-route \
  --route-table-id rtb-09c0e0248abb9757e \
  --destination-cidr-block 10.10.0.0/16 \
  --transit-gateway-id tgw-07fab25c49fed2786
```

The Terraform resource `aws_route.hub_public_to_eks` already existed in hub-vpc/main.tf but had never been applied. Running `terraform apply` on hub-vpc locked it permanently.

### How We Diagnosed Each Layer (the method)

```
Step 1: curl to EKS endpoint IPs directly
  → timeout = network problem (not auth)
  → 403 = network works, check auth

Step 2: Check route tables on the bastion's subnet
  → missing 10.10.0.0/16 route = outbound broken

Step 3: Check TGW route table
  → both VPC CIDRs present = TGW routing OK

Step 4: Check which subnets EKS ENIs are in
  → one in public subnet = return path may be missing

Step 5: Check route tables on EKS ENI subnets
  → public subnet missing 10.0.0.0/16 → TGW = return path broken

Step 6: Check TGW attachments for both VPCs
  → hub attachment missing bastion's AZ subnet = AZ routing broken

Step 7: Check NACLs
  → all open, not the problem

Step 8: Check EKS access entries
  → bastion role missing = auth would also fail after network fixed
```

### Final State (everything that's correct now)

| Check | Value | Status |
|-------|-------|--------|
| Hub public RT `10.10.0.0/16 → TGW` | rtb-09c0e0248abb9757e | ✅ |
| Hub TGW attachment subnets | public + private (both AZs) | ✅ |
| Spoke TGW attachment subnets | all 3 private subnets | ✅ |
| Spoke public RT `10.0.0.0/16 → TGW` | all 3 public RTs | ✅ |
| EKS cluster SG port 443 from `10.0.0.0/16` | sg-05f295bfd0faf2ccb | ✅ |
| Bastion role in EKS access entries | AmazonEKSClusterAdminPolicy | ✅ |
| kubectl get nodes | 3 nodes Ready | ✅ |

### Apply Order for Future Destroy/Rebuild (Bastion → EKS path)

```bash
# 1. Hub VPC first — TGW must exist before anything can attach
cd terraform/aws/hub-vpc && terraform apply

# 2. Spoke EKS second — attaches to TGW, EKS cluster, nodes
cd terraform/aws/spoke-vpc-eks && terraform apply

# 3. Bastion last — needs hub VPC subnets and SGs to exist
cd terraform/aws/bastion && terraform apply
```

### Key Lesson

> A Transit Gateway requires a subnet attachment **in the same AZ as the traffic source**. Having a route to the TGW is not enough — the TGW attachment must include a subnet in every AZ where traffic originates. Always attach TGW to all subnets in a VPC, not just one.
