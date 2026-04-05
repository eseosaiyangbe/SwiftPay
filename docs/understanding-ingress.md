# Understanding Ingress in MicroK8s: A Beginner's Guide

> **What you'll learn**: How traffic reaches your app through Kubernetes ingress, why it works on multiple nodes, and how to verify everything yourself.

---

## Table of Contents
1. [The Big Picture](#the-big-picture)
2. [Your 3-Node Cluster](#your-3-node-cluster)
3. [How Ingress Works](#how-ingress-works)
4. [Hands-On Verification](#hands-on-verification)
5. [The Complete Traffic Flow](#the-complete-traffic-flow)
6. [Common Questions](#common-questions)

---

## The Big Picture

When you type `www.payflow.local` in your browser, here's what happens:

```
Your Browser
    ↓
DNS lookup (/etc/hosts)
    ↓
Finds: www.payflow.local = 192.168.64.2
    ↓
Sends HTTPS request to 192.168.64.2:443
    ↓
NGINX Ingress Controller (on that node)
    ↓
Reads ingress rules (tls-ingress-local.yaml)
    ↓
Forwards to frontend service
    ↓
Your React App responds!
```

**The magic**: This works on ALL 3 of your nodes, not just one!

---

## Your 3-Node Cluster

### Command: See your cluster nodes
```bash
export KUBECONFIG=~/.kube/microk8s-config
kubectl get nodes -o wide
```

### What you'll see:
```
NAME             STATUS   INTERNAL-IP    ROLE
microk8s-vm      Ready    192.168.64.2   Primary node ✅
microk8s-node2   Ready    192.168.64.3   Worker node
microk8s-node3   Ready    192.168.64.4   Worker node
```

### Your `/etc/hosts` file:
```bash
cat /etc/hosts | grep payflow
```

**Expected output:**
```
192.168.64.2 api.payflow.local www.payflow.local
```

> **Note**: You're pointing to `192.168.64.2` (the primary node), but it would work with ANY of the 3 IPs!

---

## How Ingress Works

### Concept 1: DaemonSet
A **DaemonSet** ensures that **one copy** of a pod runs on **every node**.

### Command: See the ingress controller
```bash
kubectl get pods -n ingress -o wide
```

### What you'll see:
```
NAME                                      READY   NODE
nginx-ingress-microk8s-controller-xxxxx   1/1     microk8s-vm      ← Pod on node 1
nginx-ingress-microk8s-controller-yyyyy   1/1     microk8s-node2   ← Pod on node 2
nginx-ingress-microk8s-controller-zzzzz   1/1     microk8s-node3   ← Pod on node 3
```

**Key insight**: There's an NGINX pod on EVERY node!

---

### Concept 2: hostPort
Each ingress pod binds **directly** to the node's IP address on ports 80 and 443.

### Command: Verify the port configuration
```bash
kubectl describe daemonset nginx-ingress-microk8s-controller -n ingress | grep -A 2 "Host Ports"
```

### What you'll see:
```
Host Ports:  80/TCP (http), 443/TCP (https)
```

**This means:**
```
Pod on microk8s-vm      → Listens on 192.168.64.2:80 and :443
Pod on microk8s-node2   → Listens on 192.168.64.3:80 and :443
Pod on microk8s-node3   → Listens on 192.168.64.4:80 and :443
```

---

### Concept 3: Ingress Rules
The ingress controller reads your ingress resource to know where to route traffic.

### Command: See your ingress rules
```bash
kubectl get ingress -n payflow -o yaml
```

### What you'll see (simplified):
```yaml
spec:
  rules:
  - host: www.payflow.local
    http:
      paths:
      - path: /
        backend:
          service:
            name: frontend
            port:
              number: 80
  - host: api.payflow.local
    http:
      paths:
      - path: /
        backend:
          service:
            name: api-gateway
            port:
              number: 80
```

**Translation**: 
- Requests to `www.payflow.local` → forward to `frontend:80`
- Requests to `api.payflow.local` → forward to `api-gateway:80`

---

## Hands-On Verification

### Step 1: Check which ingress is deployed
```bash
kubectl get ingress -n payflow
```

**Expected:**
```
NAME                    HOSTS                                 ADDRESS     PORTS
payflow-local-ingress   api.payflow.local,www.payflow.local   127.0.0.1   80, 443
```

> **Why 127.0.0.1?** This is the internal cluster address. The real magic happens via hostPort!

---

### Step 2: Verify ingress pods are running on all nodes
```bash
kubectl get pods -n ingress -o wide
```

**Check that you see 3 pods, one on each node.**

---

### Step 3: Test connectivity from your laptop

#### Test Node 1:
```bash
curl -k https://192.168.64.2 -H "Host: www.payflow.local"
```

#### Test Node 2:
```bash
curl -k https://192.168.64.3 -H "Host: www.payflow.local"
```

#### Test Node 3:
```bash
curl -k https://192.168.64.4 -H "Host: www.payflow.local"
```

**All three should return your frontend HTML!**

> `-k` = ignore SSL certificate warnings (because you're using self-signed certs)
> `-H "Host: www.payflow.local"` = tells ingress which rule to use

---

### Step 4: See which services the ingress routes to
```bash
kubectl get svc -n payflow | grep -E "frontend|api-gateway"
```

**Expected:**
```
NAME          TYPE        CLUSTER-IP       PORT(S)
frontend      ClusterIP   10.152.183.x     80/TCP
api-gateway   ClusterIP   10.152.183.y     80/TCP
```

These are **ClusterIP** services — they're only accessible inside the cluster. The ingress is what makes them accessible from your laptop!

---

### Step 5: Verify your /etc/hosts entry
```bash
cat /etc/hosts | grep payflow
```

**Expected:**
```
192.168.64.2 api.payflow.local www.payflow.local
```

---

### Step 6: Test your domain names
```bash
curl -k https://www.payflow.local
```

This should return your PayFlow frontend HTML.

```bash
curl -k https://api.payflow.local/health
```

This should return the API Gateway health check response.

---

## The Complete Traffic Flow

```
┌──────────────────────────────────────────────────────────────┐
│  Step 1: Your Browser                                        │
│  URL: https://www.payflow.local                              │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 2: DNS Resolution                                      │
│  /etc/hosts: www.payflow.local → 192.168.64.2               │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 3: TCP Connection                                      │
│  Your laptop → 192.168.64.2:443 (MicroK8s VM)               │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 4: NGINX Ingress Controller                            │
│  - Pod running on microk8s-vm                                │
│  - Listening on 192.168.64.2:443 (via hostPort)             │
│  - Reads Host header: www.payflow.local                      │
│  - Matches ingress rule                                      │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 5: Service Discovery                                   │
│  - Looks up "frontend" service                               │
│  - Gets ClusterIP: 10.152.183.x                             │
│  - Kubernetes DNS: frontend.payflow.svc.cluster.local       │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 6: Load Balancing                                      │
│  - Service has 2 frontend pods                               │
│  - Pod 1: 10.1.69.x on microk8s-node2                       │
│  - Pod 2: 10.1.167.x on microk8s-node3                      │
│  - Kubernetes picks one (round-robin)                        │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Step 7: Frontend Pod Responds                               │
│  - Serves React app (index.html)                            │
│  - Response flows back through the same path                 │
└──────────────────────────────────────────────────────────────┘
```

---

## Why It Works on All 3 Nodes

### The DaemonSet Guarantee

```
┌─────────────────────────────────────────────────────────────┐
│  Node 1: microk8s-vm (192.168.64.2)                         │
│  ┌─────────────────────────────────────┐                    │
│  │  nginx-ingress-controller pod       │                    │
│  │  Listens on: 192.168.64.2:80/443   │  ← hostPort        │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Node 2: microk8s-node2 (192.168.64.3)                      │
│  ┌─────────────────────────────────────┐                    │
│  │  nginx-ingress-controller pod       │                    │
│  │  Listens on: 192.168.64.3:80/443   │  ← hostPort        │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Node 3: microk8s-node3 (192.168.64.4)                      │
│  ┌─────────────────────────────────────┐                    │
│  │  nginx-ingress-controller pod       │                    │
│  │  Listens on: 192.168.64.4:80/443   │  ← hostPort        │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

**Result**: You can point your `/etc/hosts` to ANY of these IPs and it will work!

---

## Common Questions

### Q1: Why not just point to one node?
**A:** You can! That's what you're doing now. But knowing all 3 work is important for:
- **High Availability**: If node 1 goes down, you can update /etc/hosts to node 2
- **Load Testing**: You can send traffic to different nodes
- **Understanding**: Helps you understand how production load balancers work

---

### Q2: What if I had a real domain (not .local)?
**A:** Instead of `/etc/hosts`, you'd create a **DNS A record**:
```
www.payflow.com  →  192.168.64.2
```

Or for high availability, you'd use **multiple A records** (DNS round-robin):
```
www.payflow.com  →  192.168.64.2
www.payflow.com  →  192.168.64.3
www.payflow.com  →  192.168.64.4
```

---

### Q3: What's the difference between hostPort and NodePort?

| Type | Port Range | Your Setup |
|------|-----------|-----------|
| **hostPort** | Uses standard ports (80, 443) | ✅ Yes |
| **NodePort** | High ports (30000-32767) | ❌ No |
| **LoadBalancer** | Cloud provider external LB | ❌ No (local cluster) |

**Why hostPort is better for local dev**: 
- You can use standard HTTPS port 443
- No need to remember port numbers like `:30443`
- Works exactly like production

---

### Q4: Where is the TLS certificate?
```bash
kubectl get secrets -n payflow | grep tls
```

Your self-signed certificate is stored as a Kubernetes secret and referenced in `tls-ingress-local.yaml`:
```yaml
tls:
- hosts:
  - api.payflow.local
  - www.payflow.local
  secretName: payflow-tls-cert
```

---

### Q5: How do I see the actual ingress configuration?
```bash
kubectl get ingress payflow-local-ingress -n payflow -o yaml
```

This shows you:
- Which hosts are configured
- Which services they route to
- TLS settings
- Path rules

---

## Advanced: Port Binding Visualization

### What happens when the ingress pod starts:

```bash
# Inside the NGINX pod on microk8s-vm
netstat -tulpn | grep :443

# Output:
tcp  0.0.0.0:443  LISTEN  nginx
     ↑
     This means: Listen on ALL network interfaces
     Including: 192.168.64.2:443 (external traffic)
```

### Compare with a regular ClusterIP service:
```bash
# A normal service pod
netstat -tulpn | grep :80

# Output:
tcp  10.1.69.123:80  LISTEN  node
     ↑
     Only accessible inside the cluster
     Not reachable from your laptop
```

**The difference**: hostPort binds to the node's external IP, not just the pod's internal IP.

---

## Testing Scenarios

### Scenario 1: Simulate Node Failure
```bash
# Update /etc/hosts to point to node 2 instead
sudo nano /etc/hosts

# Change from:
192.168.64.2 api.payflow.local www.payflow.local

# To:
192.168.64.3 api.payflow.local www.payflow.local

# Test
curl -k https://www.payflow.local
```

**Expected**: Still works! Because the ingress controller is on all nodes.

---

### Scenario 2: See Load Balancing in Action
```bash
# Watch logs from all ingress pods
kubectl logs -f -n ingress -l app.kubernetes.io/name=ingress-nginx --all-containers=true

# In another terminal, send requests
for i in {1..10}; do curl -k https://www.payflow.local; done
```

You'll see logs from the ingress pod on the node you're pointing to.

---

### Scenario 3: Test API Gateway Routing
```bash
# Test API health check
curl -k https://api.payflow.local/health

# Test a protected endpoint (will fail without auth, but proves routing works)
curl -k https://api.payflow.local/wallets/123
```

---

## Key Takeaways

1. ✅ **DaemonSet** = One ingress pod per node
2. ✅ **hostPort** = Binds to node's external IP (192.168.64.x)
3. ✅ **Ingress Rules** = Routes based on Host header
4. ✅ **ClusterIP Services** = Internal load balancing to pods
5. ✅ **Your /etc/hosts** = Points to any node IP (you chose .2)

---

## Next Steps

1. **Run all the commands** in the "Hands-On Verification" section
2. **Test connectivity** to all 3 node IPs
3. **Try the test scenarios** to see how failover works
4. **Read** `k8s/ingress/tls-ingress-local.yaml` to see the actual config

---

## Visual Cheat Sheet

```
╔════════════════════════════════════════════════════════════╗
║  YOUR LAPTOP                                               ║
║  /etc/hosts: www.payflow.local → 192.168.64.2            ║
╚═══════════════════════╦════════════════════════════════════╝
                        ║
         ┌──────────────╨──────────────┐
         │                              │
         ▼                              ▼
┌─────────────────┐            ┌─────────────────┐
│  192.168.64.2   │            │  192.168.64.3   │ (any works!)
│  microk8s-vm    │            │  microk8s-node2 │
│  ┌────────────┐ │            │  ┌────────────┐ │
│  │   NGINX    │ │            │  │   NGINX    │ │
│  │  Ingress   │ │            │  │  Ingress   │ │
│  └─────┬──────┘ │            │  └─────┬──────┘ │
└────────┼────────┘            └────────┼────────┘
         │                              │
         └──────────────┬───────────────┘
                        │
                        ▼
         ╔══════════════════════════════╗
         ║  Kubernetes Service Layer    ║
         ║  • frontend:80               ║
         ║  • api-gateway:80            ║
         ╚═══════════════╦══════════════╝
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    ┌────────┐     ┌────────┐     ┌────────┐
    │Frontend│     │Frontend│     │  API   │
    │  Pod   │     │  Pod   │     │Gateway │
    │(node2) │     │(node3) │     │  Pod   │
    └────────┘     └────────┘     └────────┘
```

---

## Troubleshooting Commands

### Ingress not working?
```bash
# 1. Check ingress pods are running
kubectl get pods -n ingress

# 2. Check ingress resource exists
kubectl get ingress -n payflow

# 3. Check service endpoints exist
kubectl get endpoints frontend -n payflow
kubectl get endpoints api-gateway -n payflow

# 4. Check ingress controller logs
kubectl logs -n ingress -l app.kubernetes.io/name=ingress-nginx --tail=50

# 5. Verify /etc/hosts
cat /etc/hosts | grep payflow

# 6. Test direct connection to node IP
curl -k https://192.168.64.2 -H "Host: www.payflow.local"
```

---

**Remember**: The beauty of Kubernetes is that once you understand these core concepts (DaemonSet, hostPort, Service, Ingress), you can apply them to ANY cluster — MicroK8s, EKS, GKE, AKS, or on-premises!

🎯 **You now understand how ingress works at a fundamental level.**

