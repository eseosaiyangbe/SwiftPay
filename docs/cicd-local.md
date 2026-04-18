# Local CI/CD: Self-hosted GitHub Actions → MicroK8s registry → Argo CD

This guide is for **SwiftPay on MicroK8s** with everything on your machine: no AWS, no Docker Hub, no cloud registry. For **cloud** builds on GitHub-hosted runners (Docker Hub / ECR / ACR), see `.github/workflows/build-and-deploy.yml` and the [documentation index](README.md).

**What you get:** push to `main` → self-hosted runner builds images → images land in the MicroK8s registry (`localhost:32000` inside the cluster) → workflow commits updated tags in `k8s/overlays/local/kustomization.yaml` → Argo CD syncs the app to namespace `swiftpay`.

**Repository workflow file:** `.github/workflows/gitops-local.yml`

**Git remote for this project:** `https://github.com/Ship-With-Zee/swiftpay-wallet.git`

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| MicroK8s | Control plane VM `microk8s-vm` (typical macOS install). Workers optional. |
| Addons | `dns`, `storage`, `registry`, `ingress`, `metrics-server` enabled on the control plane. |
| `kubectl` | `microk8s config > ~/.kube/microk8s-config` and `export KUBECONFIG=~/.kube/microk8s-config` (or use the brew `microk8s` CLI). |
| Docker | Docker Desktop (or Engine) on the **runner** machine for `docker build` / `docker save`. |
| Multipass | On **macOS**, required so the runner can run `multipass exec microk8s-vm -- ...` (registry port `32000` is **inside** the VM, not on the Mac loopback). |
| `kustomize` | On the runner: `brew install kustomize` (or install the binary yourself). Used for `kustomize edit set image`. |
| Git push from Actions | Secret `GITOPS_PAT` (fine-grained or classic PAT with **contents** write on this repo) if the default `GITHUB_TOKEN` is blocked by branch protection. |

**Why Multipass on macOS:** Docker on the Mac cannot push to `http://127.0.0.1:32000` because that port is not the host registry—it lives in the VM. The workflow mirrors `scripts/deploy-microk8s.sh`: `docker save` → `multipass transfer` → `microk8s ctr image import` → `microk8s ctr image push --plain-http` to populate the in-cluster registry (so worker nodes can pull).

**Sanity checks:**

```bash
kubectl get nodes
multipass exec microk8s-vm -- curl -sS http://127.0.0.1:32000/v2/ && echo
multipass exec microk8s-vm -- curl -sS http://127.0.0.1:32000/v2/_catalog
```

---

## 1. Install Argo CD on MicroK8s

```bash
export KUBECONFIG="${HOME}/.kube/microk8s-config"

kubectl create namespace argocd

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
```

**Initial admin password:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

**CLI (optional):**

```bash
brew install argocd
kubectl port-forward svc/argocd-server -n argocd 8443:443
argocd login localhost:8443 --username admin --insecure
```

---

## 2. Register a self-hosted GitHub Actions runner

On the **same Mac** that runs Docker and Multipass (so the workflow can reach `microk8s-vm`):

1. GitHub → your repository → **Settings** → **Actions** → **Runners** → **New self-hosted runner**.
2. Choose **macOS** (or Linux if your cluster and registry are reachable from that host without Multipass—then the workflow’s `docker push localhost:32000` path applies).
3. Run the download/config commands from the UI. Example shape (use the **exact** URL and token GitHub shows):

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# … download and extract the runner zip/tar from the UI …
./config.sh --url https://github.com/Ship-With-Zee/swiftpay-wallet --token YOUR_REGISTRATION_TOKEN
./run.sh
```

For a persistent service, follow GitHub’s docs for `./svc.sh install` on your OS.

**Runner labels:** The default self-hosted runner may have no custom labels; `gitops-local.yml` uses `runs-on: self-hosted`. If you add labels in `config.sh`, add the same labels to the workflow.

**Secrets in GitHub:** Add `GITOPS_PAT` if you need a PAT to push manifest commits (recommended if `main` is protected).

---

## 3. Workflow behavior (`gitops-local.yml`)

| Step | Behavior |
|------|----------|
| Trigger | Push to `main` or `master`, ignoring pushes that **only** change `k8s/overlays/local/kustomization.yaml` (avoids loops). The bump commit uses `[skip ci]` as a safeguard. |
| Build | Same as the rest of the repo: context `./services`, `--provenance=false`, tag `localhost:32000/<service>:<short-sha>` and `:latest`. |
| Push to registry | If `microk8s-vm` exists in `multipass list`, use **transfer + ctr import + ctr push**. Otherwise assume **Linux-style** host and `docker push` to `localhost:32000`. |
| GitOps bump | `kustomize edit set image` updates `veeno/*` entries in `k8s/overlays/local/kustomization.yaml` to the new short SHA. |
| Commit | Commits and pushes only if the kustomization changed. |

---

## 4. Connect Argo CD to the repository

**Public repo:**

```bash
argocd repo add https://github.com/Ship-With-Zee/swiftpay-wallet.git --name swiftpay
```

**Private repo (HTTPS + PAT):**

```bash
argocd repo add https://github.com/Ship-With-Zee/swiftpay-wallet.git --username git --password 'YOUR_GITHUB_PAT'
```

**Create the Application** (tracks the same overlay you use for local deploy):

```bash
argocd app create swiftpay-local \
  --repo https://github.com/Ship-With-Zee/swiftpay-wallet.git \
  --path k8s/overlays/local \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace swiftpay \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

First sync:

```bash
argocd app sync swiftpay-local
argocd app get swiftpay-local
```

---

## 5. End-to-end test

1. Runner online (`./run.sh` or service).
2. Argo CD application **Synced** / **Healthy** (or run `argocd app sync swiftpay-local` once).
3. Push a small change on `main` (e.g. a comment in a service).
4. Confirm:
   - **Actions** → workflow **Local GitOps (MicroK8s)** succeeded.
   - Registry catalog (from the VM):  
     `multipass exec microk8s-vm -- curl -sS http://127.0.0.1:32000/v2/_catalog`
   - Argo CD shows a new revision and sync.
   - Pods roll: `kubectl get pods -n swiftpay -w`

---

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| `microk8s: command not found` on Mac | Install `brew install ubuntu/microk8s/microk8s`, or run commands via `multipass exec microk8s-vm -- sudo microk8s ...`. |
| `curl http://127.0.0.1:32000` fails on Mac | Expected. Test with `multipass exec microk8s-vm -- curl ...`. |
| Workflow: `multipass: command not found` | Install Multipass; the workflow needs it on macOS for registry publish. |
| Workflow: `kustomize: command not found` | On the runner: `brew install kustomize`. |
| Infinite workflow runs | Ensure `[skip ci]` is on the bot commit and `paths-ignore` includes the kustomization path. |
| Argo CD **OutOfSync** | Wrong `--path`, private repo credentials, or manual cluster edits (enable **self-heal** or revert drift). |
| Worker nodes **ImagePullBackOff** | Images must be **pushed** into the registry pod (the workflow’s `ctr image push` path does that). Importing only into containerd without pushing is not enough for workers. |

---

## Related repo files

- `scripts/deploy-microk8s.sh` — interactive deploy; same image transfer/push pattern on macOS.
- `k8s/overlays/local/kustomization.yaml` — `images:` entries (`veeno/*` → `localhost:32000/...`) updated by CI.
- `.github/workflows/build-and-deploy.yml` — GitHub-hosted runners; Docker Hub / ECR / ACR.
