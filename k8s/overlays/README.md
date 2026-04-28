# Kustomize Overlays

Kustomize overlays for deploying SwiftPay across the current workspace and cloud targets.

## Structure

```
overlays/
├── dev/                 # Owned Phase 7 local k3s dev overlay
│   ├── kustomization.yaml
│   ├── ingress-traefik.yaml
│   ├── supplemental-networkpolicy.yaml
│   ├── infra/           # Local Postgres / Redis / RabbitMQ for repeatable dev runs
│   └── ...patches
├── prod/                # Owned production contract overlay with Vault-backed secrets
│   ├── kustomization.yaml
│   ├── ingress-traefik.yaml
│   ├── vault-secret-store.yaml
│   ├── vault-external-secrets.yaml
│   └── ...patches
├── local/               # Legacy MicroK8s learner overlay
│   ├── kustomization.yaml
│   ├── ingress-local.yaml
│   └── ...patches
├── eks/                 # AWS EKS deployment
│   ├── kustomization.yaml
│   ├── db-config-patch.yaml
│   ├── db-migration-patch.yaml
│   ├── ingress-patch.yaml
│   ├── eks-external-secrets.yaml
│   ├── patches/         # JSON patches (e.g. REDIS_URL from secret)
│   └── deploy.sh        # Automated deployment script
└── aks/                 # Azure AKS deployment
    ├── kustomization.yaml
    ├── db-config-patch.yaml
    ├── db-migration-patch.yaml
    ├── ingress-patch.yaml
    └── aks-external-secrets.yaml
```

## Quick Deploy

**k3s dev (current workspace standard):**
```bash
cd ..
./scripts/k8s-dev-deploy.sh
```

**EKS (automated):**
```bash
cd eks
./deploy.sh
```

**AKS:**
```bash
cd aks
kubectl apply -k .
```

## Documentation

For complete deployment instructions, database migrations, and troubleshooting, see:
- **[Deployment Guide](../../docs/DEPLOYMENT.md)** - Full deployment walkthrough
- **[Architecture](../../docs/architecture.md)** - System design and infrastructure
- **[Runbook](../../docs/RUNBOOK.md)** - Debugging and operations

## How It Works

- **Base resources** (`../../base/`) define shared microservice deployments
- **`dev/`** is the owned Phase 7 local `k3s` path with Traefik, self-hosted infra, and Vault-backed secret materialization
- **`prod/`** is the owned production contract path with Traefik ingress, managed dependency expectations, and Vault-backed secrets via External Secrets Operator
- **`local/`** is the older MicroK8s learner path kept for continuity
- **Cloud overlays** patch base resources with managed-service configs, cloud images, and cloud ingress
- **Database migrations** run automatically before services start
- **External Secrets** sync from Vault for the workspace-standard `prod` path, and from cloud secret stores in cloud-specific overlays
- **EKS:** `REDIS_URL` and `RABBITMQ_URL` come from Secrets Manager via External Secrets; Terraform (managed-services) writes the Redis URL after ElastiCache is created
