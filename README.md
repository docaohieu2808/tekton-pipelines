# tekton-pipelines

**Tier:** K8s-native CI highest (L6) — supply-chain security track.

**Vị trí trong learning path:**
```
(standalone track — K8s-native CI)
tekton-pipelines: Tasks → Pipeline → Triggers → Chains (SLSA provenance)
```

## Mục đích

Zero-config CI/CD pipeline chạy native trên Kubernetes: auto-detect ngôn ngữ → build → test → kaniko image build (no Docker daemon) → SBOM → SLSA provenance ký bằng cosign. EventListener nhận webhook từ GitHub / GitLab / Bitbucket / Gitea.

## Install order (quan trọng)

```bash
# 1. Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/v0.65.0/release.yaml

# 2. Tekton Triggers
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/v0.29.0/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/v0.29.0/interceptors.yaml

# 3. Tekton Chains (SLSA provenance)
kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/v0.22.0/release.yaml

# 4. Apply manifests trong repo (theo thứ tự)
kubectl apply -f tasks/
kubectl apply -f pipelines/
kubectl apply -f triggers/
kubectl apply -f chains/

# 5. Ký cosign key (Chains)
cosign generate-key-pair k8s://tekton-chains/signing-secrets
```

## Cấu trúc

```
tasks/          # Reusable Tasks: detect, build, test, kaniko, sbom, notify
pipelines/      # Pipeline orchestrating tasks
triggers/       # EventListener (GitHub/GitLab/Bitbucket/Gitea), TriggerBindings, TriggerTemplate
chains/         # Tekton Chains config: OCI storage, x509 signer, SLSA attestation
examples/       # Ví dụ đăng ký project mới với trigger
```

## Verify SLSA provenance

```bash
# Sau khi image được build và ký
cosign verify --key cosign.pub ghcr.io/myorg/myapp:sha-abc1234

# Xem attestation
cosign verify-attestation --key cosign.pub \
  --type slsaprovenance \
  ghcr.io/myorg/myapp:sha-abc1234 | jq .
```

## Webhook setup

1. Tạo secret cho từng provider:
   ```bash
   kubectl create secret generic github-webhook-secret \
     --from-literal=secret=<your-webhook-secret> -n tekton-pipelines
   ```
2. Expose EventListener qua Ingress/NodePort
3. Đăng ký webhook URL tại GitHub/GitLab repo settings

## Demo points (interview)

- Kaniko: build Docker image không cần Docker daemon (no privileged container) — security baseline
- Tekton Chains + cosign: SLSA provenance tự động → supply-chain security đang hot (SLSA level 2)
- EventListener multi-provider: 1 listener xử lý GitHub / GitLab / Bitbucket / Gitea — CEL interceptor filter
- So sánh được: Tekton Task = GitHub Actions step; Pipeline = workflow; Trigger = `on: push`
