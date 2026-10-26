#!/usr/bin/env bash
# Helpers shared by the kind end-to-end scripts. Source this file.
set -euo pipefail

export NS="${NS:-tekton-ci}"
export REGISTRY_IN_CLUSTER="registry.registry.svc.cluster.local:5000"
export GIT_IN_CLUSTER="git://git-server.git.svc.cluster.local"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

PF_PIDS=()
cleanup_port_forwards() {
  for pid in "${PF_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
}

# port_forward <namespace> <service> <local-port> <remote-port>
port_forward() {
  # Already forwarded (by an earlier call in this script)? Reuse it.
  if (exec 3<>"/dev/tcp/127.0.0.1/$3") 2>/dev/null; then return 0; fi
  kubectl port-forward -n "$1" "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS+=("$!")
  for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$3") 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "port-forward to $1/$2 did not come up" >&2
  return 1
}

# publish_fixture <fixture-dir> <repo-name>
# Pushes the fixture as branch main of git://git-server/<repo-name>.git and prints the commit SHA.
publish_fixture() {
  local dir="$1" name="$2" work
  work="$(mktemp -d)"
  cp -r "$dir/." "$work/"
  git -C "$work" init -q -b main
  git -C "$work" -c user.name=ci -c user.email=ci@example.invalid add -A
  git -C "$work" -c user.name=ci -c user.email=ci@example.invalid commit -q -m "fixture $name"
  kubectl exec -n git deploy/git-server -- sh -c \
    "git init -q --bare /srv/git/$name.git && git -C /srv/git/$name.git config uploadpack.allowAnySHA1InWant true"
  port_forward git git-server 9418 9418
  git -C "$work" push -q "git://127.0.0.1:9418/$name.git" main
  git -C "$work" rev-parse HEAD
}

# run_pipeline <repo-name> <revision>  -> prints the PipelineRun name
run_pipeline() {
  local name="$1" revision="$2"
  kubectl create -n "$NS" -o name -f - <<EOF | sed 's#.*/##'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${name}-
spec:
  pipelineRef:
    name: auto-pipeline
  params:
    - name: git-url
      value: ${GIT_IN_CLUSTER}/${name}.git
    - name: git-revision
      value: ${revision}
    - name: image
      value: ${REGISTRY_IN_CLUSTER}/${name}:ci
    - name: insecure-registry
      value: "true"
  taskRunTemplate:
    podTemplate:
      securityContext:
        fsGroup: 65532
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
    - name: docker-credentials
      secret:
        secretName: docker-registry-credentials
  timeouts:
    pipeline: 30m
    tasks: 25m
EOF
}

# wait_pipelinerun <name> <timeout-seconds>
# returns 0 when Succeeded=True, 1 when Succeeded=False, 2 on timeout
wait_pipelinerun() {
  local name="$1" end=$((SECONDS + $2)) status
  while [ "$SECONDS" -lt "$end" ]; do
    status="$(kubectl get pipelinerun "$name" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
    case "$status" in
      True) return 0 ;;
      False) return 1 ;;
    esac
    sleep 5
  done
  return 2
}

# dump_pipelinerun <name>  -- everything needed to debug a red run
dump_pipelinerun() {
  local name="$1"
  echo "::group::PipelineRun $name"
  kubectl get pipelinerun "$name" -n "$NS" -o yaml || true
  kubectl get taskrun -n "$NS" -l "tekton.dev/pipelineRun=$name" || true
  kubectl logs -n "$NS" -l "tekton.dev/pipelineRun=$name" --all-containers --prefix --tail=-1 || true
  echo "::endgroup::"
}

pipelinerun_result() { # <name> <result-name>
  kubectl get pipelinerun "$1" -n "$NS" -o jsonpath="{.status.results[?(@.name==\"$2\")].value}"
}
