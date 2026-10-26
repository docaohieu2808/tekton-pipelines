# tekton-pipelines

[![ci](https://github.com/docaohieu2808/tekton-pipelines/actions/workflows/ci.yml/badge.svg)](https://github.com/docaohieu2808/tekton-pipelines/actions/workflows/ci.yml)

**Tier L6 - Kubernetes-native CI with a supply-chain security track.**

```
Tasks  ->  Pipeline  ->  Triggers  ->  Chains (signature + SLSA provenance)
```

A zero-config CI/CD pipeline that runs inside Kubernetes: clone the repo, detect the
language, build and test in the right toolchain image, build and push an image with Buildah
(no Docker daemon), generate an SBOM, optionally deploy, and let Tekton Chains sign the image
and attach SLSA provenance. An EventListener starts it from GitHub, GitLab, Bitbucket or Gitea
webhooks, each one authenticated.

Pinned versions (checked 2026-10-26): Tekton Pipelines v1.17.1, Triggers v0.37.2, Chains
v0.29.9, Buildah v1.43.5, Syft v1.55.0, git-clone bundle v1.7.1, cosign v3.1.4 (verification
in CI). Tekton Pipelines needs Kubernetes 1.28 or newer.

## Level map

| Level | Directory | What you learn | Proven by CI |
|-------|-----------|----------------|--------------|
| L1 Tasks | `tasks/` | Task, steps, params, results, workspaces; running in the right toolchain image; params through `env`, not into scripts | kubeconform (strict, Tekton CRD schemas), shellcheck on every embedded script, run inside the pipeline |
| L2 Pipeline | `pipelines/` | Ordering, `when`, results, resolvers (git-clone from a catalog bundle) | A real PipelineRun succeeds on a fixture app; one with a failing test goes red |
| L3 Triggers | `triggers/`, `examples/` | EventListener, interceptors, bindings, template, per-run volumes, webhook authentication | Signed and unsigned webhooks are sent to the EventListener for GitHub, GitLab, Gitea and Bitbucket |
| L4 Chains | `chains/` | Signing, SLSA provenance, type-hinted results (`IMAGE_URL` / `IMAGE_DIGEST`) | The image the pipeline pushed is verified with `cosign verify` and `cosign verify-attestation` |

## Install

```bash
# Tekton Pipelines, Triggers (+ interceptors) and Chains, pinned and waited for
scripts/install-tekton.sh
```

It applies the release files from GitHub releases:

```bash
kubectl apply -f https://github.com/tektoncd/pipeline/releases/download/v1.17.1/release.yaml
kubectl apply -f https://github.com/tektoncd/triggers/releases/download/v0.37.2/release.yaml
kubectl apply -f https://github.com/tektoncd/triggers/releases/download/v0.37.2/interceptors.yaml
kubectl apply -f https://github.com/tektoncd/chains/releases/download/v0.29.9/release.yaml
```

(The old `storage.googleapis.com/tekton-releases/<project>/<version>/release.yaml` URLs return
404; `https://infra.tekton.dev/tekton-releases/<project>/previous/<version>/release.yaml` also works.)

Then the manifests of this repo, in this order:

```bash
kubectl create namespace tekton-ci

# L4 signing key (use a real password outside a lab) and config
COSIGN_PASSWORD='' cosign generate-key-pair k8s://tekton-chains/signing-secrets
kubectl apply -f chains/

# L1 + L2
kubectl apply -n tekton-ci -f tasks/
kubectl apply -n tekton-ci -f pipelines/

# L3: edit triggers/trigger-binding-pipeline-defaults-image-registry.yml first
# (image-repository = where your images go), create the webhook secrets, then
kubectl apply -n tekton-ci -f triggers/
```

## Run a level locally

You need a cluster; `kind create cluster` is enough.

**Run the pipeline without any webhook** (L1 + L2). Needs a git URL the cluster can reach,
a registry the cluster can push to, and a Secret with a Docker `config.json`:

```bash
kubectl create secret generic docker-registry-credentials -n tekton-ci \
  --from-file=config.json=$HOME/.docker/config.json
kubectl create -n tekton-ci -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: demo-
spec:
  pipelineRef: {name: auto-pipeline}
  params:
    - {name: git-url,      value: https://github.com/<you>/<repo>.git}
    - {name: git-revision, value: main}
    - {name: image,        value: ghcr.io/<you>/<repo>:demo}
  taskRunTemplate:
    podTemplate:
      securityContext: {fsGroup: 65532}   # git-clone runs as uid 65532
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
    - name: docker-credentials
      secret: {secretName: docker-registry-credentials}
EOF
kubectl get pipelinerun -n tekton-ci -w
```

The tests in `tests/fixtures/` are tiny Node apps (one passes, one has a failing test); the
exact end-to-end run CI does is `ci/bootstrap-cluster.sh` followed by the `ci/test-*.sh`
scripts, and you can run them on your own kind cluster in the same order.

**Webhooks (L3).** Create the secrets (`github-webhook-secret`, `gitlab-webhook-secret`,
`gitea-webhook-secret`, `bitbucket-webhook-secret`, key `secret`), publish the Service
`el-git-webhook-listener` (port 8080) through an Ingress with TLS, and register the URL in the
provider with the same secret:

```bash
kubectl create secret generic github-webhook-secret -n tekton-ci --from-literal=secret=<random>
```

**Verify what Chains signed (L4):**

```bash
kubectl get pipelinerun <name> -n tekton-ci -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'   # true
kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub
cosign verify --key cosign.pub <registry>/<repo>@<IMAGE_DIGEST>
cosign verify-attestation --key cosign.pub --type slsaprovenance1 <registry>/<repo>@<IMAGE_DIGEST>
```

(Add `--insecure-ignore-tlog` while `transparency.enabled` is `"false"`.)

## What changed from the first version, and why

- **Install URLs** were 404; versions were two years old. Now GitHub release assets, current releases.
- **Kaniko is archived** (Google, June 2025). The image Task now uses **Buildah** (`tasks/task-build-and-push-image-with-buildah.yml`),
  with `vfs` storage and only the `SETFCAP` capability, no privileged pod.
- **Chains signs the real image.** The Task and the Pipeline emit results named `IMAGE_URL` and `IMAGE_DIGEST`
  (the lower-case `image-digest` names were invisible to Chains).
- **Chains config** uses valid formats (`slsa/v2alpha3` = SLSA provenance v1.0; `slsaprovenance1` does not exist) and no placeholders.
- **Build and test run in language images** (`node`, `golang`, `maven`, `gradle`, `python`, `composer`, `rust`) chosen by the
  `detect-language` Task, instead of `alpine` with no toolchain. Failing tests fail the Task.
- **git-clone** comes from the `tektoncd-catalog` bundle through the bundles resolver (Tekton Hub is archived).
- **Bitbucket** is authenticated with the `bitbucket` interceptor and a shared secret; before, anyone with the URL could start builds.
  The EventListener is exposed as a ClusterIP Service for an Ingress with TLS, not a plain-HTTP LoadBalancer.
- **RBAC** uses the ClusterRoles shipped by Triggers; the RoleBinding subject has its namespace.
- **SBOM** (Syft, called directly because its image has no shell) is now wired into the pipeline and runs against the pushed image.
- **Script injection**: every param reaches scripts through `env`, and CI fails on `$(params.*)` inside a script.
- **Deploy** verifies SSH host keys (a `known_hosts` file is required), validates values that reach a remote shell, and installs
  `kubectl`/`helm` from the Alpine repositories instead of piping a script from `main`.
- Per-run `volumeClaimTemplate` workspaces replace the shared ReadWriteOnce PVC.

## What CI checks

`.github/workflows/ci.yml` runs on every push and pull request, on `workflow_dispatch`, and every
Monday 03:23 UTC.

- **lint**: `yamllint --strict`; `shellcheck` on `ci/` and `scripts/`; `shellcheck` on every step script embedded in a Task
  (and a rule that `$(params.*)` never appears in a script); `kubeconform -strict` on all manifests with JSON schemas
  generated from the CRDs of the pinned Tekton releases (`ci/generate-tekton-crd-schemas.sh`).
- **e2e** on a kind cluster: install Pipelines, Triggers and Chains; start a registry and a git server inside the cluster;
  apply the manifests; run `auto-pipeline` on `tests/fixtures/node-pass` (Dockerfile generated, image built with Buildah and pushed,
  SBOM generated, `IMAGE_DIGEST` returned), wait for Chains to sign, then `cosign verify` and `cosign verify-attestation` with the
  generated key, and check that a wrong key is rejected; run `tests/fixtures/node-fail` and require a red PipelineRun with no
  image; send signed and badly signed webhooks for each provider to the EventListener.

## Honest limits

- The `deploy` Task (ssh, docker-compose, k8s, helm, S3 + CloudFront, rsync) and the `notify-slack-webhook` Task need servers,
  clusters, AWS or Slack, so CI checks them statically (kubeconform, shellcheck) and the pipeline run uses `deploy-target=skip`.
- CI exercises Node end to end. The other detected languages (`java`, `go`, `python`, `php`, `rust`) use the same mechanism and
  their toolchain images are pinned, but only Node has a fixture.
- The registry in CI is plain HTTP and has no login; the signing key has an empty password. Neither is a production setting.
  `transparency.enabled` is `"false"`, so signatures are not in the public Rekor log.
- `pipeline` results no longer include `deploy-url`: a result that points at a task skipped by `when` cannot be resolved.
  Read `deploy-url` from the `deploy` TaskRun.
- Gitea is verified through the GitHub-compatible headers it sends (`X-Hub-Signature-256`, `X-GitHub-Event`).
- `skip-docker-build` was removed: the image is the product of the pipeline, and the signed results depend on it.
  Use `skip-push=true` to build without pushing (nothing is signed then).

## Interview talking points

- Buildah in a pod without privileges (`SETFCAP` only, `vfs`) vs Kaniko (archived) vs BuildKit rootless.
- Chains finds images by the `IMAGE_URL` / `IMAGE_DIGEST` result names; no custom signing step in the pipeline.
- Why every webhook provider needs its own authentication, and why the EventListener sits behind TLS.
- Tekton Task = GitHub Actions job's steps, Pipeline = workflow, Trigger = `on: push`, Chains = provenance you cannot forget to add.

## License

MIT, see `LICENSE`.
