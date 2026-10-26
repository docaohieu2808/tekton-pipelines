#!/usr/bin/env bash
# Builds JSON schemas for the Tekton CRDs so kubeconform can validate Tasks, Pipelines,
# PipelineRuns, EventListeners, TriggerTemplates... in strict mode. The CRDs come from the
# same release files scripts/install-tekton.sh installs, so schema and cluster always agree.
# Usage: ci/generate-tekton-crd-schemas.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: $0 <output-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PIPELINES_VERSION="$(grep -oP 'PIPELINES_VERSION:-\K[^}]+' "$HERE/../scripts/install-tekton.sh")"
TRIGGERS_VERSION="$(grep -oP 'TRIGGERS_VERSION:-\K[^}]+' "$HERE/../scripts/install-tekton.sh")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

curl -fsSL "https://github.com/tektoncd/pipeline/releases/download/${PIPELINES_VERSION}/release.yaml" -o "$WORK/pipeline.yaml"
curl -fsSL "https://github.com/tektoncd/triggers/releases/download/${TRIGGERS_VERSION}/release.yaml" -o "$WORK/triggers.yaml"

# Keep only the CustomResourceDefinition documents.
python3 -I - "$WORK" <<'PY'
import sys, yaml
work = sys.argv[1]
for name in ("pipeline", "triggers"):
    docs = [d for d in yaml.safe_load_all(open(f"{work}/{name}.yaml"))
            if d and d.get("kind") == "CustomResourceDefinition"]
    with open(f"{work}/{name}-crds.yaml", "w") as out:
        yaml.safe_dump_all(docs, out)
PY

python3 -I "$HERE/crd-to-jsonschema.py" "$OUT" "$WORK/pipeline-crds.yaml" "$WORK/triggers-crds.yaml"
