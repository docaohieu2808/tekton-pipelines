#!/usr/bin/env bash
# Sends real webhooks to the EventListener and checks the authentication of every provider:
#   * a correctly signed GitHub push and a correctly signed Bitbucket push start a PipelineRun
#     that builds and pushes an image;
#   * a wrongly signed GitHub push and an unsigned Bitbucket push start nothing;
#   * correctly authenticated GitLab and Gitea pushes also start a PipelineRun.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
trap cleanup_port_forwards EXIT

secret() { kubectl get secret "$1-webhook-secret" -n "$NS" -o jsonpath='{.data.secret}' | base64 -d; }
hmac() { printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | awk '{print $NF}'; }
run_count() { kubectl get pipelinerun -n "$NS" -o name | wc -l; }

sha_pass="$(publish_fixture tests/fixtures/node-pass fixture-hook)"
sha_bb="$(publish_fixture tests/fixtures/node-pass fixture-bb)"
port_forward "$NS" el-git-webhook-listener 8080 8080
clone() { echo "${GIT_IN_CLUSTER}/$1.git"; }

# post <expected-new-runs> <description> <curl args...>
post() {
  local expected="$1" what="$2" before after
  shift 2
  before="$(run_count)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080 "$@")"
  sleep 15
  after="$(run_count)"
  if [ $((after - before)) -ne "$expected" ]; then
    echo "FAIL $what: HTTP $code, expected $expected new PipelineRun(s), got $((after - before))" >&2
    kubectl logs -n "$NS" -l eventlistener=git-webhook-listener --tail=40 >&2 || true
    exit 1
  fi
  echo "ok   $what (HTTP $code, $expected new PipelineRun)"
}

github_body="{\"ref\":\"refs/heads/main\",\"after\":\"${sha_pass}\",\"repository\":{\"name\":\"fixture-hook\",\"clone_url\":\"$(clone fixture-hook)\"},\"pusher\":{\"name\":\"ci\",\"login\":\"ci\"}}"
bb_body="{\"push\":{\"changes\":[{\"new\":{\"type\":\"branch\",\"name\":\"main\",\"target\":{\"hash\":\"${sha_bb}\"}}}]},\"repository\":{\"name\":\"fixture-bb\",\"links\":{\"html\":{\"href\":\"$(clone fixture-bb)\"}}},\"actor\":{\"nickname\":\"ci\"}}"

# --- must be rejected ---
post 0 "github push with a wrong signature is rejected" \
  -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' \
  -H "X-Hub-Signature-256: sha256=$(hmac wrong-secret "$github_body")" --data "$github_body"
post 0 "bitbucket push without a signature is rejected" \
  -H 'Content-Type: application/json' -H 'X-Event-Key: repo:push' --data "$bb_body"
post 0 "bitbucket push signed with the wrong secret is rejected" \
  -H 'Content-Type: application/json' -H 'X-Event-Key: repo:push' \
  -H "X-Hub-Signature: sha256=$(hmac wrong-secret "$bb_body")" --data "$bb_body"

# --- must start a run ---
gh_secret="$(secret github)"
post 1 "github push with a valid signature starts a PipelineRun" \
  -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' \
  -H "X-Hub-Signature-256: sha256=$(hmac "$gh_secret" "$github_body")" --data "$github_body"
bb_secret="$(secret bitbucket)"
post 1 "bitbucket push with a valid signature starts a PipelineRun" \
  -H 'Content-Type: application/json' -H 'X-Event-Key: repo:push' \
  -H "X-Hub-Signature: sha256=$(hmac "$bb_secret" "$bb_body")" --data "$bb_body"

# GitLab and Gitea: only check that an authenticated event is accepted. Their runs are
# cancelled right away to save CI time; the two runs above already prove the pipeline itself.
gitlab_body="{\"ref\":\"refs/heads/main\",\"after\":\"${sha_pass}\",\"checkout_sha\":\"${sha_pass}\",\"project\":{\"name\":\"fixture-hook\",\"http_url\":\"$(clone fixture-hook)\"},\"user_username\":\"ci\"}"
post 1 "gitlab push with the right token starts a PipelineRun" \
  -H 'Content-Type: application/json' -H 'X-Gitlab-Event: Push Hook' \
  -H "X-Gitlab-Token: $(secret gitlab)" --data "$gitlab_body"
post 0 "gitlab push with a wrong token is rejected" \
  -H 'Content-Type: application/json' -H 'X-Gitlab-Event: Push Hook' \
  -H 'X-Gitlab-Token: wrong' --data "$gitlab_body"
gitea_secret="$(secret gitea)"
post 1 "gitea push with a valid signature starts a PipelineRun" \
  -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' \
  -H "X-Hub-Signature-256: sha256=$(hmac "$gitea_secret" "$github_body")" --data "$github_body"

# Cancel the runs of the gitlab and gitea pushes, then wait for the github and bitbucket runs.
mapfile -t runs < <(kubectl get pipelinerun -n "$NS" -l tekton.dev/pipeline=auto-pipeline \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#runs[@]}" -eq 4 ] || { echo "FAIL: expected 4 PipelineRuns, found ${#runs[@]}" >&2; exit 1; }
for i in 2 3; do
  kubectl patch pipelinerun "${runs[$i]}" -n "$NS" --type=merge -p '{"spec":{"status":"Cancelled"}}'
done

for i in 0 1; do
  rc=0
  wait_pipelinerun "${runs[$i]}" 900 || rc=$?
  if [ "$rc" -ne 0 ]; then
    dump_pipelinerun "${runs[$i]}"
    echo "FAIL: webhook-triggered PipelineRun ${runs[$i]} did not succeed" >&2
    exit 1
  fi
done

port_forward registry registry 5000 5000
for pair in "fixture-hook:${sha_pass}" "fixture-bb:${sha_bb}"; do
  repo="${pair%%:*}"; tag="${pair##*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
    "http://localhost:5000/v2/${repo}/manifests/${tag}")"
  [ "$code" = "200" ] || { echo "FAIL: image ${repo}:${tag} is not in the registry (HTTP $code)" >&2; exit 1; }
  echo "ok   image ${repo}:${tag} was built by the webhook-triggered run and pushed"
done
