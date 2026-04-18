#!/bin/bash
# ============================================================
# SwiftPay Infrastructure — DESTROY Script
# Destroys all AWS resources in the correct dependency order
# Safe to run: confirms before destroying each module; skips missing workspaces; continues on module failure
# ============================================================

set -e

# Prevent AWS CLI from using a pager (script would appear stuck)
export AWS_PAGER=""

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
# Run from repo root so terraform/aws is correct
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_ROOT="$REPO_ROOT/terraform/aws"
DYNAMODB_TABLE="${TFSTATE_DYNAMODB_TABLE:-swiftpay-tfstate-lock}"
FAILED_MODULES=0

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
  local dir="$TF_ROOT/$module"
  local plan_ok=0

  banner "DESTROYING: $module"
  log "$description"
  echo ""

  if [ ! -d "$dir" ]; then
    warn "Directory $dir not found — skipping"
    return 0
  fi

  cd "$dir"

  # Init with full backend config so it works regardless of backend.tf contents
  log "Initialising Terraform..."
  if ! terraform init -reconfigure -input=false \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    -backend-config="region=$REGION" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    > /tmp/tf-init.log 2>&1; then
    warn "Init failed for $module (wrong account or missing bucket?). Skipping."
    cat /tmp/tf-init.log
    cd "$REPO_ROOT"
    return 0
  fi

  # Use same workspace as environment (must match what was used for apply)
  if ! terraform workspace select "$ENVIRONMENT" 2>/dev/null; then
    warn "Workspace '$ENVIRONMENT' not found for $module — nothing to destroy. Skipping."
    cd "$REPO_ROOT"
    return 0
  fi

  # Plan destroy; skip apply if plan fails (no valid plan file)
  log "Planning destroy..."
  if terraform plan -destroy -input=false -var="environment=$ENVIRONMENT" -out=/tmp/destroy.plan > /tmp/tf-plan.log 2>&1; then
    plan_ok=1
  else
    warn "Plan failed for $module:"
    cat /tmp/tf-plan.log
  fi

  # Count resources only if we have a valid plan
  if [ "$plan_ok" -eq 1 ]; then
    RESOURCE_COUNT=$(terraform show -json /tmp/destroy.plan 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([r for r in d.get('resource_changes',[]) if r.get('change',{}).get('actions',[])==['delete']]))" 2>/dev/null || echo "?")
    echo ""
    echo -e "${YELLOW}  Resources to destroy: ${BOLD}$RESOURCE_COUNT${NC}"
    echo ""
  else
    echo ""
    warn "Skipping destroy for $module (no valid plan)."
    cd "$REPO_ROOT"
    return 0
  fi

  read -p "  Destroy $module? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    warn "Skipped $module"
    cd "$REPO_ROOT"
    return 0
  fi

  echo ""
  log "Destroying $module..."
  if terraform apply -destroy -input=false /tmp/destroy.plan; then
    success "$module destroyed successfully"
  else
    warn "$module destroy failed (e.g. dependency or timeout). Continuing with remaining modules."
    FAILED_MODULES=$((FAILED_MODULES + 1))
  fi

  cd "$REPO_ROOT"
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

# Confirm the account before destroying anything (generic — works for any account)
warn "About to destroy infrastructure in account: ${ACCOUNT} (region: ${REGION})"

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
echo "  1. managed-services  (RDS, ElastiCache, Amazon MQ)"
echo "  2. spoke-vpc-eks     (EKS cluster, nodes, ECR, WAF, GuardDuty)"
echo "  3. bastion           (EC2 bastion host)"
echo "  4. hub-vpc           (Transit Gateway, VPC, NAT gateways)"
echo ""
echo -e "  ${GREEN}NOT destroyed:${NC} S3 state bucket, DynamoDB lock table"
echo ""

read -p "  Ready to start? (yes/no): " start_confirm
[ "$start_confirm" != "yes" ] && { echo "Aborted."; exit 0; }

START_TIME=$(date +%s)

# ── Destroy in order ─────────────────────────────────────────

destroy_module "managed-services" \
  "RDS PostgreSQL, ElastiCache Redis, Amazon MQ RabbitMQ (~15 min)"

destroy_module "spoke-vpc-eks" \
  "EKS cluster + nodes, spoke VPC, ECR repos, WAF, GuardDuty, IAM roles (~10 min)"

destroy_module "bastion" \
  "Bastion EC2 instance, IAM role, security group (~2 min)"

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
if [ $ISSUES -eq 0 ] && [ "${FAILED_MODULES:-0}" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✓ ALL CLEAR — Infrastructure fully destroyed${NC}"
  echo -e "${GREEN}${BOLD}  Cost now: ~\$0.02/month (S3 state bucket only)${NC}"
  echo -e "${GREEN}${BOLD}  Time taken: ${ELAPSED} minutes${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
  [ "${FAILED_MODULES:-0}" -gt 0 ] && echo -e "${YELLOW}${BOLD}  $FAILED_MODULES module(s) had destroy errors. Re-run destroy.sh for those modules after fixing.${NC}"
  if [ $ISSUES -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}  ⚠ $ISSUES resource type(s) may still be running (EKS/NAT/TGW/EC2)${NC}"
    echo -e "${YELLOW}  Check the warnings above and investigate manually${NC}"
  fi
fi
echo ""
