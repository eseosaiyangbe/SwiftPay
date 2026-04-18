# Bastion Host Access Guide

> **Purpose**: Step-by-step guide for accessing EKS/AKS clusters via Bastion host

---

## Prerequisites

1. **SSH Key**: Private key for Bastion access (`.pem` or `.ppk` file)
2. **Bastion IP**: Elastic IP or public IP of Bastion host
3. **AWS CLI**: Configured with appropriate credentials
4. **kubectl**: Installed on your local machine (optional, can install on Bastion)

---

## Accessing EKS via Bastion

### Step 1: SSH to Bastion Host

```bash
# Replace with your Bastion IP and key path
ssh -i ~/.ssh/swiftpay-bastion-key.pem ec2-user@<bastion-ip>
```

**Note**: If you're using Windows, use PuTTY or WSL.

### Step 2: Configure kubectl for EKS

Once connected to Bastion:

```bash
# Configure kubectl to connect to EKS cluster
aws eks update-kubeconfig \
  --region us-east-1 \
  --name swiftpay-eks-cluster

# Verify access
kubectl get nodes
```

Expected output:
```
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-10-1-xxx.ec2.internal   Ready    <none>   5m    v1.28.x
ip-10-10-2-xxx.ec2.internal   Ready    <none>   5m    v1.28.x
```

### Step 3: Access Kubernetes Resources

```bash
# List all namespaces
kubectl get namespaces

# List pods in swiftpay namespace
kubectl get pods -n swiftpay

# View logs
kubectl logs -n swiftpay <pod-name>

# Execute commands in pod
kubectl exec -it -n swiftpay <pod-name> -- /bin/sh

# Port forward (access service locally)
kubectl port-forward -n swiftpay svc/api-gateway 8080:80
```

---

## Accessing AKS via Bastion (Azure)

### Step 1: SSH to Azure Bastion

```bash
ssh -i ~/.ssh/swiftpay-azure-key.pem azureuser@<bastion-ip>
```

### Step 2: Configure kubectl for AKS

```bash
# Login to Azure (if not already)
az login

# Get AKS credentials
az aks get-credentials \
  --resource-group swiftpay-rg \
  --name swiftpay-aks-cluster

# Verify access
kubectl get nodes
```

---

## Local Access via SSH Tunnel (Alternative)

If you prefer to use kubectl from your local machine:

### Step 1: Create SSH Tunnel

```bash
# Forward local port 6443 to EKS API endpoint via Bastion
ssh -i ~/.ssh/swiftpay-bastion-key.pem \
  -L 6443:<eks-api-endpoint>:443 \
  ec2-user@<bastion-ip> -N
```

### Step 2: Configure kubectl with Tunnel

```bash
# Get EKS API endpoint
aws eks describe-cluster \
  --name swiftpay-eks-cluster \
  --region us-east-1 \
  --query 'cluster.endpoint' \
  --output text

# Update kubeconfig to use localhost:6443
kubectl config set-cluster swiftpay-eks-cluster \
  --server=https://127.0.0.1:6443 \
  --insecure-skip-tls-verify
```

**Note**: This method is more complex and not recommended for production.

---

## Security Best Practices

### 1. Use SSH Key Authentication Only

- Never use password authentication
- Store private keys securely (use SSH agent)
- Rotate keys regularly (every 90 days)

### 2. Limit Bastion Access

- Update Security Group to allow only your IP:
  ```bash
  # Get your public IP
  curl ifconfig.me
  
  # Update Terraform variable
  authorized_ssh_cidrs = ["<your-ip>/32"]
  ```

### 3. Enable Session Recording

- All commands on Bastion are logged to CloudWatch (AWS) / Azure Monitor
- Review logs regularly for security audits

### 4. Use IAM Roles

- Bastion uses IAM role for EKS access
- No need to store AWS credentials on Bastion
- Rotate IAM roles regularly

### 5. MFA for Production

- Enable MFA for IAM users accessing Bastion
- Use AWS SSO or Azure AD for enterprise access

---

## Troubleshooting

### Issue: Cannot SSH to Bastion

**Check**:
1. Security Group allows your IP on port 22
2. Bastion instance is running
3. SSH key has correct permissions: `chmod 400 ~/.ssh/swiftpay-key.pem`

### Issue: kubectl Connection Refused

**Check**:
1. EKS cluster endpoint is private (expected)
2. Transit Gateway routes are configured
3. Security Groups allow HTTPS (443) from Bastion to EKS subnets

### Issue: Permission Denied for EKS

**Check**:
1. IAM user/role has `eks:DescribeCluster` permission
2. AWS credentials are configured: `aws configure list`
3. IAM role is attached to Bastion instance

### Issue: Cannot Access Pods

**Check**:
1. Pods are running: `kubectl get pods -n swiftpay`
2. Network policies allow traffic
3. Service account has proper RBAC permissions

---

## Quick Commands Reference

```bash
# Connect to EKS
aws eks update-kubeconfig --region us-east-1 --name swiftpay-eks-cluster

# View cluster info
kubectl cluster-info

# Get all resources
kubectl get all -n swiftpay

# Describe pod
kubectl describe pod <pod-name> -n swiftpay

# View events
kubectl get events -n swiftpay --sort-by='.lastTimestamp'

# Check node resources
kubectl top nodes

# Check pod resources
kubectl top pods -n swiftpay

# View service endpoints
kubectl get endpoints -n swiftpay

# Debug network connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup postgres
```

---

## Next Steps

After accessing the cluster:

1. **Deploy SwiftPay Services**: Use manifests from `k8s/` directory
2. **Install Ingress Controller**: AWS Load Balancer Controller
3. **Configure Monitoring**: Prometheus, Grafana
4. **Set Up CI/CD**: ArgoCD or Flux for GitOps

---

**Remember**: Bastion is your only entry point. Keep it secure! 🔒

