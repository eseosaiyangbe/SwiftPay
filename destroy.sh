#!/bin/bash
# ============================================================
# SwiftPay Infrastructure — DESTROY Script
# Destroys all AWS resources in the correct dependency order
# Safe to run: confirms before destroying each module
# ============================================================

set -e

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ───────────────────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$SCRIPT_DIR/terraform/aws"

# ── Helpers ──────────────────────────────────────────────────
log()     { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

banner() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

destroy_module() {
  local module=$1
  local description=$2
  local extra_vars="${3:-}"
  local dir="$TF_ROOT/$module"
  local plan_ok=false
  local use_refresh_false=false

  banner "DESTROYING: $module"
  log "$description"
  echo ""

  if [ ! -d "$dir" ]; then
    warn "Directory $dir not found — skipping"
    return 0
  fi

  cd "$dir"

  # Init silently (in case .terraform dir is missing after fresh clone)
  log "Initialising Terraform..."
  terraform init -reconfigure -input=false \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    > /tmp/tf-init.log 2>&1 \
    || { warn "Init had warnings — continuing anyway"; cat /tmp/tf-init.log; }

  # Use same workspace as environment (must match what was used for apply)
  terraform workspace select "$ENVIRONMENT" 2>/dev/null || { warn "Workspace $ENVIRONMENT not found — is this the right environment?"; }

  # Show what will be destroyed (extra_vars e.g. -var-file for modules needing secrets)
  log "Planning destroy..."
  if terraform plan -destroy -input=false -var="environment=$ENVIRONMENT" ${extra_vars:+ $extra_vars} -out=/tmp/destroy.plan > /tmp/tf-plan.log 2>&1; then
    plan_ok=true
  else
    warn "Plan had issues:"
    cat /tmp/tf-plan.log
    if grep -qE "force-unlock|Error locking state" /tmp/tf-plan.log 2>/dev/null; then
      echo ""
      warn "Stale state lock detected. Run: cd $dir && terraform force-unlock <LOCK_ID>"
      warn "Use the Lock ID from the error above, then re-run this script."
    fi
    # spoke-vpc-eks: if hub was destroyed first, data sources or remote state fail. Retry with -refresh=false.
    if [ "$module" = "spoke-vpc-eks" ] && ! grep -qE "force-unlock|Error locking state" /tmp/tf-plan.log 2>/dev/null && grep -qE "no matching EC2 VPC found|query returned no results|Failed to get existing workspaces|Error reading.*output" /tmp/tf-plan.log 2>/dev/null; then
      log "Hub appears gone or unreachable. Retrying plan with -refresh=false (uses cached state)..."
      if terraform plan -destroy -refresh=false -input=false -var="environment=$ENVIRONMENT" -var="hub_tfstate_bucket=$TFSTATE_BUCKET" ${extra_vars:+ $extra_vars} -out=/tmp/destroy.plan > /tmp/tf-plan.log 2>&1; then
        plan_ok=true
        use_refresh_false=true
      else
        warn "Retry with -refresh=false also failed. Check /tmp/tf-plan.log"
      fi
    fi
  fi

  # Count resources
  RESOURCE_COUNT=$(terraform show -json /tmp/destroy.plan 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([r for r in d.get('resource_changes',[]) if r.get('change',{}).get('actions',[])==['delete']]))" 2>/dev/null || echo "?")

  echo ""
  echo -e "${YELLOW}  Resources to destroy: ${BOLD}$RESOURCE_COUNT${NC}"
  echo ""

  read -p "  Destroy $module? (yes/no): " confirm
  # Accept "yes" or "y" (case-insensitive)
  if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
    warn "Skipped $module (type 'yes' or 'y' to destroy)"
    cd "$SCRIPT_DIR"
    return 0
  fi

  echo ""
  log "Destroying $module..."
  if [ "$plan_ok" = true ] && [ -f /tmp/destroy.plan ]; then
    if terraform apply -destroy -input=false /tmp/destroy.plan; then
      success "$module destroyed successfully"
    else
      # Fallback: if apply with plan fails, try direct destroy (e.g. plan file stale)
      warn "Apply with plan failed. Trying terraform destroy..."
      local fallback_opts="-input=false -var=environment=$ENVIRONMENT ${extra_vars:+ $extra_vars} -auto-approve"
      [ "$module" = "spoke-vpc-eks" ] && fallback_opts="-input=false -var=environment=$ENVIRONMENT -var=hub_tfstate_bucket=$TFSTATE_BUCKET ${extra_vars:+ $extra_vars} -auto-approve"
      [ "$use_refresh_false" = true ] && fallback_opts="$fallback_opts -refresh=false"
      if terraform destroy $fallback_opts; then
        success "$module destroyed successfully"
      else
        error "$module destroy failed. Fix the error and re-run."
      fi
    fi
  else
    # No valid plan: run destroy directly. For spoke when hub is gone, use -refresh=false.
    local destroy_opts="-input=false -var=environment=$ENVIRONMENT ${extra_vars:+ $extra_vars} -auto-approve"
    [ "$module" = "spoke-vpc-eks" ] && destroy_opts="-input=false -var=environment=$ENVIRONMENT -var=hub_tfstate_bucket=$TFSTATE_BUCKET ${extra_vars:+ $extra_vars} -auto-approve"
    [ "$module" = "spoke-vpc-eks" ] && grep -qE "no matching EC2 VPC found|query returned no results|Failed to get existing workspaces|Error reading.*output" /tmp/tf-plan.log 2>/dev/null && destroy_opts="$destroy_opts -refresh=false"
    if terraform destroy $destroy_opts; then
      success "$module destroyed successfully"
    else
      error "$module destroy failed. Fix the error and re-run."
    fi
  fi

  cd "$SCRIPT_DIR"
  echo ""
}

# ── Pre-flight checks ─────────────────────────────────────────
clear
echo ""
echo -e "${RED}${BOLD}"
echo "  ██████╗ ███████╗███████╗████████╗██████╗  ██████╗ ██╗   ██╗"
echo "  ██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗ ██╔╝"
echo "  ██║  ██║█████╗  ███████╗   ██║   ██████╔╝██║   ██║ ╚████╔╝ "
echo "  ██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██╗██║   ██║  ╚██╔╝  "
echo "  ██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╔╝   ██║   "
echo "  ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝    ╚═╝  "
echo -e "${NC}"
echo -e "${BOLD}  SwiftPay Infrastructure Destroy Script${NC}"
echo -e "  This will destroy: EKS cluster, RDS, Redis, MQ, TGW, VPCs, NAT gateways"
echo -e "  ${GREEN}Safe:${NC} S3 state bucket and DynamoDB lock table are never touched"
echo ""

# Check AWS CLI is configured
log "Checking AWS credentials..."
ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region $REGION 2>/dev/null) \
  || error "AWS CLI not configured. Run: aws configure"
success "Authenticated as account: $ACCOUNT"

# Check terraform installed
command -v terraform > /dev/null 2>&1 || error "Terraform not installed"
TF_VERSION=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || terraform version | head -1)
success "Terraform: $TF_VERSION"

TFSTATE_BUCKET="swiftpay-tfstate-${ACCOUNT}"

# Ask which environment/workspace to destroy (dev or prod) unless already set
# For managed-services and spoke-vpc-eks, ensure required vars are set (terraform.tfvars or TF_VAR_*),
# e.g. db_password, rabbitmq_password (managed-services); db_password, mq_password, jwt_secret (spoke-vpc-eks).
if [ -n "${TF_ENVIRONMENT:-}" ]; then
  ENVIRONMENT="$TF_ENVIRONMENT"
  log "Environment/workspace to destroy: $ENVIRONMENT (from TF_ENVIRONMENT)"
else
  echo ""
  echo -e "${BLUE}  Which environment do you want to DESTROY?${NC}"
  echo "    dev   — development"
  echo "    prod  — production"
  echo ""
  read -p "  Enter dev or prod [prod]: " ENVIRONMENT
  ENVIRONMENT="${ENVIRONMENT:-prod}"
  if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "prod" ]; then
    error "Invalid environment. Use 'dev' or 'prod'."
  fi
  success "Will destroy environment / workspace: $ENVIRONMENT"
fi
echo ""

echo ""
echo -e "${YELLOW}${BOLD}  DESTROY ORDER:${NC}"
echo "  1. finops            (Budgets, anomaly detection, billing alarms)"
echo "  2. managed-services  (RDS, ElastiCache, Amazon MQ)"
echo "  3. spoke-vpc-eks     (EKS cluster, nodes, ECR, WAF, GuardDuty)"
echo "  4. bastion           (EC2 bastion host)"
echo "  5. hub-vpc           (Transit Gateway, VPC, NAT gateways)"
echo ""
echo -e "  ${GREEN}NOT destroyed:${NC} S3 state bucket, DynamoDB lock table"
echo ""

read -p "  Ready to start? (yes/no): " start_confirm
[ "$start_confirm" != "yes" ] && { echo "Aborted."; exit 0; }

START_TIME=$(date +%s)

# ── Destroy in order ─────────────────────────────────────────

destroy_module "finops" \
  "FinOps budgets, anomaly detection, billing alarms (~1 min)"

destroy_module "managed-services" \
  "RDS PostgreSQL, ElastiCache Redis, Amazon MQ RabbitMQ (~15 min)" \
  "$([ -f "$TF_ROOT/managed-services/terraform.tfvars" ] && echo "-var-file=$TF_ROOT/managed-services/terraform.tfvars")"

destroy_module "spoke-vpc-eks" \
  "EKS cluster + nodes, spoke VPC, ECR repos, WAF, GuardDuty, IAM roles (~10 min)" \
  "-var=hub_tfstate_bucket=$TFSTATE_BUCKET $([ -f "$TF_ROOT/spoke-vpc-eks/terraform.tfvars" ] && echo "-var-file=$TF_ROOT/spoke-vpc-eks/terraform.tfvars")"

destroy_module "bastion" \
  "Bastion EC2 instance, IAM role, security group (~2 min)"

# Pre-check: hub cannot be destroyed while spoke (EKS) or bastion still exist
banner "PRE-CHECK: hub-vpc"
EKS_STATUS=$(aws eks describe-cluster --name swiftpay-eks-cluster --region $REGION --query 'cluster.status' --output text 2>/dev/null || echo "none")
BASTION_IDS=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Name,Values=swiftpay-bastion" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr -d '\n')
if [ "$EKS_STATUS" = "ACTIVE" ]; then
  error "EKS cluster swiftpay-eks-cluster still exists. Destroy spoke-vpc-eks first (type 'yes' when prompted)."
fi
if [ -n "$BASTION_IDS" ]; then
  error "Bastion instance(s) still running. Destroy bastion first (type 'yes' when prompted)."
fi
success "Pre-check passed: spoke and bastion are destroyed"
echo ""

destroy_module "hub-vpc" \
  "Transit Gateway, hub VPC, NAT gateways, Internet Gateway, route tables (~3 min)"

# ── Post-destroy verification ────────────────────────────────
banner "VERIFICATION"

log "Checking for remaining billable resources..."
echo ""

EKS=$(aws eks list-clusters --region $REGION --query 'clusters' --output text 2>/dev/null)
NAT=$(aws ec2 describe-nat-gateways --region $REGION \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
TGW=$(aws ec2 describe-transit-gateway-vpc-attachments --region $REGION \
  --filter Name=state,Values=available \
  --query 'TransitGatewayVpcAttachments[].TransitGatewayAttachmentId' --output text 2>/dev/null)
EC2=$(aws ec2 describe-instances --region $REGION \
  --filter Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)

ISSUES=0

if [ -z "$EKS" ]; then
  success "EKS clusters:         none (saving \$0.10/hr)"
else
  warn    "EKS clusters still running: $EKS"
  ISSUES=$((ISSUES+1))
fi

if [ -z "$NAT" ]; then
  success "NAT gateways:         none (saving \$0.135/hr)"
else
  warn    "NAT gateways still running: $NAT"
  ISSUES=$((ISSUES+1))
fi

if [ -z "$TGW" ]; then
  success "TGW attachments:      none (saving \$0.10/hr)"
else
  warn    "TGW attachments still active: $TGW"
  ISSUES=$((ISSUES+1))
fi

if [ -z "$EC2" ]; then
  success "EC2 instances:        none (saving \$0.0416/hr)"
else
  warn    "EC2 instances still running: $EC2"
  ISSUES=$((ISSUES+1))
fi

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
if [ $ISSUES -eq 0 ]; then
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✓ ALL CLEAR — Infrastructure fully destroyed${NC}"
  echo -e "${GREEN}${BOLD}  Cost now: ~\$0.02/month (S3 state bucket only)${NC}"
  echo -e "${GREEN}${BOLD}  Time taken: ${ELAPSED} minutes${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
  echo -e "${YELLOW}${BOLD}  ⚠ Destroy complete but $ISSUES resource(s) may still be running${NC}"
  echo -e "${YELLOW}  Check the warnings above and investigate manually${NC}"
fi
echo ""