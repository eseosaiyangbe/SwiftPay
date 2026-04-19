# AKS: amqplib Incompatibility with Azure Service Bus

## Critical Issue

**Break 10:** The SwiftPay application uses `amqplib` (AMQP 0-9-1 protocol) to connect to RabbitMQ. Azure Service Bus uses AMQP 1.0, which is a completely different protocol. These are **architecturally incompatible**.

## Current State

- **EKS (AWS):** Uses Amazon MQ (RabbitMQ) - ✅ Compatible with amqplib
- **AKS (Azure):** Uses Azure Service Bus - ❌ **Incompatible with amqplib**

## Impact

On AKS deployments:
- Transaction processing will fail (cannot publish to queue)
- Notifications will fail (cannot consume from queue)
- Error: Protocol mismatch / connection refused

## Solutions

### Option 1: Deploy Self-Hosted RabbitMQ in AKS (Recommended)

Deploy RabbitMQ as a Kubernetes deployment in AKS instead of using Azure Service Bus:

```yaml
# k8s/infrastructure/rabbitmq.yaml (already exists)
# Use this for AKS instead of Service Bus
```

**Pros:**
- No code changes needed
- Same protocol (AMQP 0-9-1) as EKS
- Consistent behavior across clouds

**Cons:**
- You manage RabbitMQ (updates, backups)
- Not a managed service

### Option 2: Rewrite Messaging Code (Major Refactor)

Replace `amqplib` with `@azure/service-bus` SDK:

```javascript
// Current (amqplib - AMQP 0-9-1)
const connection = await amqp.connect(RABBITMQ_URL);
const channel = await connection.createChannel();

// New (@azure/service-bus - AMQP 1.0)
const { ServiceBusClient } = require("@azure/service-bus");
const client = new ServiceBusClient(RABBITMQ_URL);
const sender = client.createSender("transactions");
```

**Required Changes:**
- Replace all `amqplib` imports with `@azure/service-bus`
- Rewrite all queue publish/consume logic
- Update error handling
- Test thoroughly

**Pros:**
- Uses managed Azure Service Bus
- No infrastructure to manage

**Cons:**
- Major code refactor (all services)
- Different code paths for EKS vs AKS
- Higher maintenance burden

## Recommendation

**Use Option 1** (self-hosted RabbitMQ) for now:
1. No code changes required
2. Consistent across EKS and AKS
3. Can migrate to Option 2 later if needed

## Implementation

### Step 1: Add RabbitMQ to AKS Overlay

Edit `k8s/overlays/aks/kustomization.yaml` and add RabbitMQ to resources:

```yaml
resources:
  - ../../base
  - ../../infrastructure/rabbitmq.yaml  # Add this line
  - aks-external-secrets.yaml
```

### Step 2: Update ConfigMap to Use Local RabbitMQ

Edit `k8s/overlays/aks/db-config-patch.yaml` and change the RABBITMQ_URL:

```yaml
# Change from Service Bus:
# RABBITMQ_URL: "Endpoint=sb://swiftpay-servicebus-prod.servicebus.windows.net/;..."

# To local RabbitMQ service:
RABBITMQ_URL: "amqp://rabbitmq:5672"  # Kubernetes service name
```

**Note:** The service name `rabbitmq` matches the Service defined in `k8s/infrastructure/rabbitmq.yaml`.

### Step 3: Ensure Secrets Include RabbitMQ Credentials

The RabbitMQ deployment reads credentials from `db-secrets`. Ensure your External Secrets Operator (or manual secrets) includes:
- `RABBITMQ_USER`
- `RABBITMQ_PASSWORD`

These should match what's in `k8s/secrets/db-secrets.yaml.example` for local development.

### Step 4: Deploy

```bash
cd k8s/overlays/aks
kubectl apply -k .
```

### Step 5: Verify RabbitMQ is Running

```bash
kubectl get pods -n swiftpay | grep rabbitmq
kubectl get svc -n swiftpay | grep rabbitmq
```

### Optional: Remove Service Bus from Terraform

If you're not using Azure Service Bus anymore, you can remove it from `terraform/azure/managed-services/servicebus.tf` to avoid confusion and reduce costs.

