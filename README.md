# Tekton Pipelines — Auto-Detect Build + Triggers + Chains Supply Chain Security

Kubernetes-native CI/CD using Tekton Pipelines, Triggers, and Chains. Auto-detects language from source, builds Docker images with Kaniko, deploys to multiple targets, and signs artifacts with cosign (SLSA provenance).

## Architecture

```
Git push → webhook → EventListener (GitHub/GitLab/Bitbucket/Gitea)
                            ↓
                   TriggerBinding (extract git-url, revision, sha)
                            ↓
                   TriggerTemplate (create PipelineRun per project)
                            ↓
                   Pipeline: clone → detect → build → test → docker → deploy
                            ↓
                   Tekton Chains: sign image + generate SLSA provenance
```

Everything runs as Kubernetes pods. No persistent agents. One EventListener handles all Git providers.

---

## Levels

| Level | What you get |
|-------|-------------|
| **L1** | Install Tekton + apply pipeline manifests. Trigger runs manually via `tkn`. |
| **L2** | Install Triggers. Webhook from any Git provider auto-creates PipelineRuns on push. |
| **L3** | Register projects via `Trigger` objects — one per repo, pointing at shared EventListener. |
| **L4** | Add SBOM generation (Syft) and Slack notifications to pipeline. |
| **MAX** | Install Tekton Chains. Every TaskRun is automatically signed with cosign. SLSA provenance stored as OCI attestation. |

---

## Prerequisites

- Kubernetes cluster (K3s or any K8s ≥ 1.26)
- `kubectl` configured
- `tkn` CLI installed (`brew install tektoncd-cli` or [releases](https://github.com/tektoncd/cli/releases))
- Container registry accessible from cluster (ghcr.io, Harbor, etc.)

---

## Installation

### 1. Install Tekton components

```bash
# Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Tekton Triggers (for webhook automation)
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

# Tekton Chains (for supply chain security — optional)
kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml

# Tekton Dashboard (optional UI)
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

### 2. Create namespace and apply manifests

```bash
kubectl create namespace tekton-pipelines

# Apply tasks, pipeline, triggers (order matters)
kubectl apply -f tasks/ -n tekton-pipelines
kubectl apply -f pipelines/ -n tekton-pipelines
kubectl apply -f triggers/ -n tekton-pipelines
```

### 3. Create required cluster-level secrets

```bash
# Docker registry credentials (for Kaniko image push)
kubectl create secret docker-registry docker-credentials \
  --docker-server=ghcr.io \
  --docker-username=<your-username> \
  --docker-password=<your-pat> \
  -n tekton-pipelines

# Webhook HMAC secrets (one per Git provider you use)
kubectl create secret generic github-webhook-secret \
  --from-literal=secret=<random-secret> \
  -n tekton-pipelines

kubectl create secret generic gitlab-webhook-secret \
  --from-literal=secret=<gitlab-token> \
  -n tekton-pipelines
```

### 4. Expose the EventListener

```bash
# Get the EventListener service IP/port
kubectl get svc -n tekton-pipelines | grep el-git-webhook-listener

# Expose via LoadBalancer or Ingress — point your Git webhook to:
# http://<EXTERNAL-IP>:8080
```

---

## Quick Start — Register a new project

Copy `examples/example-register-new-project-with-trigger.yml`, fill in placeholders, apply:

```bash
cp examples/example-register-new-project-with-trigger.yml my-api-trigger.yml
vim my-api-trigger.yml   # replace all <CHANGE_ME> values

kubectl apply -f my-api-trigger.yml -n tekton-pipelines
```

This creates:
- A `PersistentVolumeClaim` for the source workspace
- A `Trigger` wired to the shared EventListener

Then configure the webhook in your Git provider:
- **URL**: `http://<EventListener-IP>:8080`
- **Content-Type**: `application/json`
- **Secret**: matches `github-webhook-secret` / `gitlab-webhook-secret`
- **Events**: push only

Push a commit — a `PipelineRun` is created automatically.

### Monitor runs

```bash
# Watch pipeline runs
tkn pipelinerun list -n tekton-pipelines
tkn pipelinerun logs -f <run-name> -n tekton-pipelines

# Or via dashboard
kubectl port-forward svc/tekton-dashboard 9097:9097 -n tekton-pipelines
# Open http://localhost:9097
```

---

## Pipeline Parameters

The `auto-pipeline` Pipeline accepts:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `git-url` | — | Git repository URL (https or ssh) |
| `git-revision` | `main` | Branch, tag, or commit SHA |
| `git-commit-sha` | `""` | Full SHA (injected by TriggerBinding) |
| `image` | — | Full image ref to build: `registry/org/app:tag` |
| `skip-docker-build` | `false` | Skip Kaniko build step |
| `skip-push` | `false` | Build image without pushing |
| `skip-tests` | `false` | Skip test task |
| `deploy-target` | `skip` | `ssh-build\|docker-compose\|k8s\|helm\|s3-cloudfront\|rsync\|skip` |
| `ssh-host` | `""` | SSH host for ssh/docker-compose targets |
| `ssh-user` | `deploy` | SSH username |
| `ssh-port` | `22` | SSH port |
| `remote-dir` | — | Remote deploy path |

---

## Tasks Reference

| Task file | What it does |
|-----------|-------------|
| `task-detect-language-from-project-files.yml` | Inspects workspace, outputs `language` and `build-tool` |
| `task-build-application-by-detected-language.yml` | Runs language-specific build command |
| `task-run-tests-by-detected-language.yml` | Runs language-specific tests |
| `task-build-docker-image-with-kaniko.yml` | Rootless Docker image build + push using Kaniko |
| `task-deploy-to-multiple-targets-ssh-k8s-helm-s3.yml` | Deploys to configured target |
| `task-generate-sbom-with-syft-and-upload-artifact.yml` | Generates SBOM with Syft, uploads as artifact |
| `task-notify-slack-webhook-with-build-status.yml` | Posts build status to Slack webhook |

---

## Tekton Chains — Supply Chain Security (MAX level)

Chains automatically intercepts every completed TaskRun and:
1. Signs the image with cosign (Sigstore keyless or KMS key)
2. Generates SLSA provenance attestation
3. Stores signatures + attestations as OCI artifacts alongside the image

### Setup

```bash
# Generate cosign keypair stored as K8s secret
cosign generate-key-pair k8s://tekton-chains/signing-secrets

# Apply chains config
kubectl apply -f chains/tekton-chains-slsa-cosign-oci-storage-config.yaml

# Restart chains controller
kubectl rollout restart deploy/tekton-chains-controller -n tekton-chains
```

### Verify signing is working

```bash
# After a TaskRun completes:
TR=$(kubectl get taskrun -n tekton-pipelines -o name | head -1)
kubectl get $TR -n tekton-pipelines \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
# Expected output: true
```

### Verify image signature

```bash
cosign verify \
  --key k8s://tekton-chains/signing-secrets \
  ghcr.io/myorg/myapp:abc1234
```

---

## Supported Git Providers (EventListener)

| Provider | Interceptor | Header verified |
|----------|------------|-----------------|
| GitHub | `github` ClusterInterceptor | `X-Hub-Signature-256` (HMAC-SHA256) |
| GitLab | `gitlab` ClusterInterceptor | `X-Gitlab-Token` |
| Bitbucket | `bitbucket` ClusterInterceptor | `X-Hub-Signature` |
| Gitea | CEL + header match | `X-Gitea-Signature` |

---

## Repository Structure

```
tekton-pipelines/
├── tasks/
│   ├── task-detect-language-from-project-files.yml
│   ├── task-build-application-by-detected-language.yml
│   ├── task-run-tests-by-detected-language.yml
│   ├── task-build-docker-image-with-kaniko.yml
│   ├── task-deploy-to-multiple-targets-ssh-k8s-helm-s3.yml
│   ├── task-generate-sbom-with-syft-and-upload-artifact.yml
│   └── task-notify-slack-webhook-with-build-status.yml
├── pipelines/
│   └── pipeline-auto-detect-build-test-docker-deploy.yml
├── triggers/
│   ├── event-listener-webhook-github-gitlab-bitbucket-gitea.yml
│   ├── trigger-binding-extract-git-info-from-webhook.yml
│   └── trigger-template-create-pipelinerun-per-project.yml
├── chains/
│   ├── tekton-chains-slsa-cosign-oci-storage-config.yaml
│   └── tekton-chains-verify-signing-working-pipelinerun.yaml
└── examples/
    └── example-register-new-project-with-trigger.yml
```
