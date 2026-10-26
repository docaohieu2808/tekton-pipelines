#!/usr/bin/env bash
# Installs Tekton Pipelines, Triggers and Chains on the current (kind) cluster, starts the
# test registry and git server, creates the signing key and webhook secrets, then applies
# every manifest of this repo the way the README says. Fails on the first error.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/install-tekton.sh

kubectl apply -f ci/manifests/registry-and-git-server.yaml
kubectl rollout status deployment/registry -n registry --timeout=180s
kubectl rollout status deployment/git-server -n git --timeout=180s

# Chains signing key. Empty password only because this is a throw-away CI cluster.
COSIGN_PASSWORD='' cosign generate-key-pair k8s://tekton-chains/signing-secrets
kubectl apply -f chains/
# The CI registry speaks plain HTTP; production keeps the default (false).
kubectl patch configmap chains-config -n tekton-chains --type merge \
  -p '{"data":{"storage.oci.repository.insecure":"true"}}'

kubectl create namespace tekton-ci
# Webhook secrets: random per run, kept in the cluster and read back by the webhook test.
for provider in github gitlab gitea bitbucket; do
  kubectl create secret generic "${provider}-webhook-secret" -n tekton-ci \
    --from-literal=secret="$(openssl rand -hex 16)"
done
# Empty Docker config: the CI registry needs no login, but the pipeline binds the workspace.
kubectl create secret generic docker-registry-credentials -n tekton-ci \
  --from-literal=config.json='{"auths":{}}'

kubectl apply -n tekton-ci -f tasks/
kubectl apply -n tekton-ci -f pipelines/
# The triggers directory minus the registry defaults, which CI replaces with its own.
for f in triggers/*.yml; do
  case "$f" in *pipeline-defaults*) continue ;; esac
  kubectl apply -n tekton-ci -f "$f"
done
kubectl apply -n tekton-ci -f ci/manifests/pipeline-defaults-for-test-registry.yaml

kubectl wait --for=condition=Ready eventlistener/git-webhook-listener -n tekton-ci --timeout=180s
echo "==> cluster ready"
kubectl get task,pipeline,eventlistener -n tekton-ci
