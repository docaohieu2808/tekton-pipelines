#!/usr/bin/env bash
# Runs auto-pipeline on the passing fixture and proves the whole chain:
# the PipelineRun succeeds, the image is in the registry, Tekton Chains signed it and attached
# SLSA provenance, and cosign verifies both against the public key.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
trap cleanup_port_forwards EXIT

sha="$(publish_fixture tests/fixtures/node-pass fixture-pass)"
run="$(run_pipeline fixture-pass main)"
echo "==> PipelineRun $run (commit $sha)"

rc=0
wait_pipelinerun "$run" 900 || rc=$?
if [ "$rc" -ne 0 ]; then
  dump_pipelinerun "$run"
  echo "FAIL: PipelineRun did not succeed (rc=$rc)" >&2
  exit 1
fi

digest="$(pipelinerun_result "$run" IMAGE_DIGEST)"
url="$(pipelinerun_result "$run" IMAGE_URL)"
echo "==> IMAGE_URL=$url IMAGE_DIGEST=$digest"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: IMAGE_DIGEST is not a sha256 digest" >&2; exit 1; }
[ "$url" = "${REGISTRY_IN_CLUSTER}/fixture-pass:ci" ] || { echo "FAIL: unexpected IMAGE_URL" >&2; exit 1; }

# The SBOM task ran against the pushed image and wrote a non-empty SPDX document.
kubectl get taskrun -n "$NS" -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=generate-sbom" \
  -o jsonpath='{.items[0].status.results[?(@.name=="package-count")].value}' | tee /tmp/package-count
echo
[ "$(cat /tmp/package-count)" -gt 0 ] || { echo "FAIL: SBOM has no packages" >&2; exit 1; }

# Chains signs asynchronously: wait for the annotation on the PipelineRun and the build TaskRun.
build_tr="$(kubectl get taskrun -n "$NS" -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=docker-build" -o name | sed 's#.*/##')"
for obj in "pipelinerun/$run" "taskrun/$build_tr"; do
  signed=""
  for _ in $(seq 1 60); do
    signed="$(kubectl get "$obj" -n "$NS" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}')"
    [ "$signed" = "true" ] && break
    sleep 5
  done
  if [ "$signed" != "true" ]; then
    echo "FAIL: Chains did not sign $obj" >&2
    kubectl logs -n tekton-chains deploy/tekton-chains-controller --tail=100 || true
    exit 1
  fi
  echo "ok   Chains signed $obj"
done

# Verify with cosign from outside the cluster, against the public key in the Secret.
kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub
port_forward registry registry 5000 5000
ref="localhost:5000/fixture-pass@${digest}"

# Chains writes the signature and the two attestations (TaskRun and PipelineRun) to the same
# registry tags one after the other, so give the registry a moment to hold the final state.
verified=""
for _ in $(seq 1 12); do
  if cosign verify --key /tmp/cosign.pub --allow-insecure-registry --insecure-ignore-tlog "$ref" > /tmp/verify.json 2>/tmp/verify.err; then
    verified=yes
    break
  fi
  sleep 5
done
if [ -z "$verified" ]; then
  cat /tmp/verify.err >&2
  echo "registry tags after the run:" >&2
  curl -s http://localhost:5000/v2/fixture-pass/tags/list >&2 || true
  kubectl logs -n tekton-chains deploy/tekton-chains-controller --tail=60 >&2 || true
  echo "FAIL: cosign could not verify the image signature" >&2
  exit 1
fi
jq -e --arg d "$digest" '.[0].critical.image["docker-manifest-digest"] == $d' /tmp/verify.json >/dev/null
echo "ok   cosign verify: signature is valid for $digest"

cosign verify-attestation --key /tmp/cosign.pub --allow-insecure-registry --insecure-ignore-tlog \
  --type slsaprovenance1 "$ref" > /tmp/attestation.json
jq -s -e '.[0].payload | @base64d | fromjson | .predicateType == "https://slsa.dev/provenance/v1"' /tmp/attestation.json >/dev/null
echo "ok   cosign verify-attestation: SLSA provenance v1 is valid"

# The check must be able to fail: a different key must be rejected.
COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix /tmp/other >/dev/null
if cosign verify --key /tmp/other.pub --allow-insecure-registry --insecure-ignore-tlog "$ref" >/dev/null 2>&1; then
  echo "FAIL: cosign accepted a signature with the wrong key" >&2
  exit 1
fi
echo "ok   a wrong public key is rejected"
