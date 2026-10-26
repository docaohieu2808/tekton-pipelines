#!/usr/bin/env bash
# Validates every manifest in the repo against the Kubernetes and Tekton schemas, strict mode.
# Requires kubeconform and the schemas from ci/generate-tekton-crd-schemas.sh.
# Usage: ci/validate-manifests-with-kubeconform.sh <schema-dir>
set -euo pipefail

SCHEMAS="$(cd "${1:?usage: $0 <schema-dir>}" && pwd)"
cd "$(dirname "$0")/.."

kubeconform -strict -summary -verbose \
  -schema-location default \
  -schema-location "${SCHEMAS}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  tasks pipelines triggers chains examples ci/manifests
