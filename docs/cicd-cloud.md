# Cloud CI/CD: Dev-First Runtime, Publish Images, Manual Promotion

This guide describes the current **cloud** CI/CD contract for SwiftPay on GitHub-hosted runners.

The active runtime truth for this repository is the public `dev` slice:

- host: `https://swiftpay.eseosadevbox.com`
- namespace: `swiftpay-dev`
- Argo CD application: `swiftpay-dev`

It is intentionally split into clear lanes:

1. `validate.yml`
   - verifies repository integrity
   - checks service dependency installation
   - validates frontend build
   - renders and dry-runs Kubernetes overlays

2. `publish-images.yml`
   - builds service images
   - publishes immutable `git short SHA` tags
   - may also publish mutable `latest` aliases for operator convenience
   - does not mutate any cluster
   - does not change GitOps manifests

3. `smoke-dev-public.yml`
   - verifies the active public `dev` edge
   - checks `/` and `/api/health`
   - proves that the live browser path and gateway health path are reachable

4. `gitops-local.yml`
   - remains the separate local-only promotion path for MicroK8s + Argo CD

## Current production boundary

SwiftPay does **not** yet have a dedicated cloud GitOps promotion workflow comparable to the local MicroK8s path.

That is an intentional constraint today.

For EKS and AKS, promotion remains:

- image publish in CI
- manual operator approval
- explicit deploy script execution with an immutable tag

That is more honest than pretending the repo already has a cloud GitOps controller path when it does not.

## Current cloud release flow

### 1. Validate

Repository validation runs through:

- `.github/workflows/validate.yml`

### 2. Publish immutable images

Cloud image publishing runs through:

- `.github/workflows/publish-images.yml`

The workflow publishes images for:

- Docker Hub
- Amazon ECR
- Azure Container Registry

The immutable release tag is the Git short SHA from the workflow run.

### 3. Verify the public dev edge

The active public runtime is verified through:

- `.github/workflows/smoke-dev-public.yml`

This workflow checks:

- `https://swiftpay.eseosadevbox.com/`
- `https://swiftpay.eseosadevbox.com/api/health`

### 4. Promote to EKS

After image publishing completes and an operator approves release:

```bash
IMAGE_TAG=<git-sha-from-ci> ./k8s/overlays/eks/deploy.sh
```

### 5. Promote to AKS

After image publishing completes and an operator approves release:

```bash
ACR_NAME=<your-acr> IMAGE_TAG=<git-sha-from-ci> ./k8s/overlays/aks/deploy.sh
```

## Why this split is better

- validation failures do not get mixed with registry publishing
- the live public `dev` runtime has an explicit smoke lane
- registry publishing does not pretend to be deployment
- local GitOps stays separate from cloud release behavior
- production deployment remains explicitly approval-gated
- operators can promote a known immutable image tag instead of a mutable alias

## Remaining gap

The next maturity step for SwiftPay cloud CI/CD is a **true cloud GitOps promotion lane**.

That would require:

- a Git-managed deployment source of truth for EKS and AKS
- promotion by manifest change or pull request
- optional smoke workflow after promotion

Until that exists, the current publish-plus-manual-promotion model is the correct and honest production contract.
