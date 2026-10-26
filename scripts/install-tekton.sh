#!/usr/bin/env bash
# Installs Tekton Pipelines, Triggers (with interceptors) and Chains into the current
# kubectl context and waits until each is ready. Versions are pinned here on purpose;
# bump them together after reading the release notes.
#
# Release assets come from GitHub releases (the old storage.googleapis.com/tekton-releases
# URLs return 404 now; infra.tekton.dev/tekton-releases/<project>/previous/<version>/ also works).
set -euo pipefail

PIPELINES_VERSION="${PIPELINES_VERSION:-v1.17.1}"
TRIGGERS_VERSION="${TRIGGERS_VERSION:-v0.37.2}"
CHAINS_VERSION="${CHAINS_VERSION:-v0.29.9}"

release() { echo "https://github.com/tektoncd/$1/releases/download/$2/$3"; }

echo "==> Tekton Pipelines ${PIPELINES_VERSION}"
kubectl apply -f "$(release pipeline "$PIPELINES_VERSION" release.yaml)"
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

echo "==> Tekton Triggers ${TRIGGERS_VERSION}"
kubectl apply -f "$(release triggers "$TRIGGERS_VERSION" release.yaml)"
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s
kubectl apply -f "$(release triggers "$TRIGGERS_VERSION" interceptors.yaml)"
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

echo "==> Tekton Chains ${CHAINS_VERSION}"
kubectl apply -f "$(release chains "$CHAINS_VERSION" release.yaml)"
kubectl wait --for=condition=Available deployment --all -n tekton-chains --timeout=300s

echo "==> Tekton is ready"
