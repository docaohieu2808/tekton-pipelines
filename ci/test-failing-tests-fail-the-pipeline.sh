#!/usr/bin/env bash
# A fixture whose unit test fails must turn the PipelineRun red and must not build or push an image.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
trap cleanup_port_forwards EXIT

publish_fixture tests/fixtures/node-fail fixture-fail >/dev/null
run="$(run_pipeline fixture-fail main)"
echo "==> PipelineRun $run"

rc=0
wait_pipelinerun "$run" 600 || rc=$?
if [ "$rc" -ne 1 ]; then
  dump_pipelinerun "$run"
  echo "FAIL: expected the PipelineRun to fail (rc=$rc, 0=succeeded, 2=timeout)" >&2
  exit 1
fi

test_status="$(kubectl get taskrun -n "$NS" -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=test" \
  -o jsonpath='{.items[0].status.conditions[0].status}')"
[ "$test_status" = "False" ] || { echo "FAIL: the test task should be the one that failed" >&2; exit 1; }

built="$(kubectl get taskrun -n "$NS" -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=docker-build" -o name)"
[ -z "$built" ] || { echo "FAIL: an image build started although the tests failed" >&2; exit 1; }

port_forward registry registry 5000 5000
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/v2/fixture-fail/manifests/ci)"
[ "$code" = "404" ] || { echo "FAIL: registry answered $code for the image of a failed run" >&2; exit 1; }
echo "ok   failing test turned the pipeline red; no image was built or pushed"
