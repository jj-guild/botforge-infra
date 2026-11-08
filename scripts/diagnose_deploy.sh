#!/usr/bin/env bash
# Diagnose a stuck or slow botforge-infra deployment (ADR-0018 chain).
#
# Learned from the 2026-09-24 prod incident: a run left `waiting` on a
# deleted/older workflow version holds the `deploy-<env>` concurrency
# group, and every newer run stays `pending` forever — no notification,
# no deployment status, the runner is never even asked. This script
# checks, in order, the four blocking causes and prints the fix:
#
#   1. stale runs (waiting/pending/queued) ahead in the `deploy-<env>`
#      concurrency group — including runs of deleted workflows and runs
#      asking for a single comma-joined label (the pre-fromJSON bug);
#   2. an environment approval pending on the newest run
#      (required reviewers, no notification by default);
#   3. the per-attempt state of the newest deploy run;
#   4. deployment statuses (waiting -> queued -> in_progress -> success).
#
# Usage:
#   scripts/diagnose_deploy.sh <env>            # human report
#   scripts/diagnose_deploy.sh <env> --json    # machine-readable single object
#
# Exit codes: 0 healthy or only advisories, 1 a blocking cause is found,
# 2 usage error. Requires: gh (read access to botforge-infra).
set -euo pipefail

usage="usage: diagnose_deploy.sh <env> [--json]"
env_name="${1:?$usage}"
shift || true
json_out=false
if [[ "${1:-}" == "--json" ]]; then
  json_out=true
elif [[ $# -gt 0 ]]; then
  echo "$usage" >&2
  exit 2
fi

repo="jj-guild/botforge-infra"

# Only the Deploy environment chain holds the deploy-<env> concurrency
# group: a run matters here when it routes a deployment for this env —
# either the current deploy.yml path or any older workflow version that
# targeted the same state branch (deleted workflow files keep running).
# Runs of other envs hold other groups and are ignored.
env_branch="deploy/${env_name}"

fetch_runs() {
  gh api "repos/${repo}/actions/runs?status=${1}&per_page=50" \
    --jq '.workflow_runs[] | [.id, .name, .head_branch, .created_at] | @tsv' 2>/dev/null || true
}

pending_ids() {
  { fetch_runs waiting; fetch_runs pending; fetch_runs queued; } \
    | awk -F'\t' -v branch="$env_branch" '$3 == branch {print $1}' | sort -n
}

# newest deploy run for the env's state branch
newest_run_json="$(gh api "repos/${repo}/actions/runs?branch=deploy/${env_name}&per_page=1" \
  --jq '.workflow_runs[0] | {id, name, status, conclusion, run_attempt, created_at, html_url}')" || true

stale_runs=""
for id in $(pending_ids); do
  detail="$(gh api "repos/${repo}/actions/runs/${id}" \
    --jq '{id, name, status, created_at, html_url, path} | @json' 2>/dev/null || true)"
  [[ -z "$detail" ]] && continue
  case "$detail" in
    *'"status":"completed"'*) continue ;;
  esac
  stale_runs="${stale_runs}${detail}\n"
done

# broken labels on the deploy job of a pending run: a single
# comma-joined string label is the pre-fromJSON runs-on bug
broken_label_runs=""
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  labels="$(gh api "repos/${repo}/actions/runs/${id}/jobs" \
    --jq '[.jobs[] | select(.labels != null) | .labels[]] | join(",")' 2>/dev/null || true)"
  if [[ -n "$labels" ]] && [[ "$labels" != *"|"* ]] \
     && [[ "$labels" == *"self-hosted,botforge,env-"* ]] \
     && [[ $(gh api "repos/${repo}/actions/runs/${id}/jobs" --jq '[.jobs[].labels | length] | max' 2>/dev/null || echo 0) -lt 3 ]]; then
    broken_label_runs="${broken_label_runs}${id}\n"
  fi
done < <(printf '%s\n' "$(pending_ids)")

approval_pending=""
if [[ -n "$newest_run_json" ]]; then
  newest_id="$(printf '%s' "$newest_run_json" | jq -r '.id')"
  p="$(gh api "repos/${repo}/actions/runs/${newest_id}/pending_deployments" \
    --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$p" != "0" ]]; then
    approval_pending="$newest_id"
  fi
fi

deployment_status=""
if [[ -n "$newest_run_json" ]]; then
  newest_id="$(printf '%s' "$newest_run_json" | jq -r '.id')"
  deployment_status="$(gh api "repos/${repo}/actions/runs/${newest_id}/attempts/$(printf '%s' "$newest_run_json" | jq -r '.run_attempt')/jobs" \
    --jq '[.jobs[] | select(.name | contains("Deploy")) | {name, status, conclusion, runner_name, labels}]' 2>/dev/null || true)"
fi

blocking=false
[[ -n "$stale_runs" ]] && blocking=true
[[ -n "$approval_pending" ]] && blocking=true

# Advisory: queued runs of deploy workflows that no longer exist (the
# workflow file was deleted/refactored away) never start and never hold a
# concurrency group — harmless, but they clutter the queue; cancel them.
dead_runs=""
existing_paths="$(gh api "repos/${repo}/actions/workflows" --jq '[.workflows[].path]' 2>/dev/null || echo '[]')"
for id in $(fetch_runs queued | awk -F'\t' '{print $1}'); do
  path="$(gh api "repos/${repo}/actions/runs/${id}" --jq '.path' 2>/dev/null || true)"
  [[ -z "$path" ]] && continue
  if ! printf '%s' "$existing_paths" | jq -e --arg p "$path" 'index($p) != null' >/dev/null 2>&1; then
    url="$(gh api "repos/${repo}/actions/runs/${id}" --jq '.html_url' 2>/dev/null || true)"
    dead_runs="${dead_runs}${id}\t${url}\n"
  fi
done

if $json_out; then
  jq -n \
    --arg env "$env_name" \
    --argjson newest "${newest_run_json:-null}" \
    --argjson stale "$(printf "$stale_runs" | jq -s '.' 2>/dev/null || echo '[]')" \
    --argjson approval_pending_id "${approval_pending:-null}" \
    --argjson deploy_jobs "${deployment_status:-[]}" \
    --argjson blocking "$blocking" \
    '{environment: $env, newest_run: $newest, stale_runs: $stale,
      approval_pending_run: $approval_pending_id, deploy_jobs: $deploy_jobs, blocking: $blocking}'
  if [[ "$blocking" == true ]]; then exit 1; fi
  exit 0
fi

echo "==> Deploy diagnose: ${env_name}"
if [[ -n "$newest_run_json" ]]; then
  printf '%s' "$newest_run_json" | jq -r '"    newest run: \(.id) \(.status) (\(.created_at)) \(.html_url)"'
fi
if [[ -n "$stale_runs" ]]; then
  echo "!! BLOCKING: stale in-flight runs (waiting/pending/queued) exist:"
  printf "$stale_runs" | jq -r '"       - \(.id) [\(.status)] \(.name) (\(.created_at)) \(.html_url)"'
  echo "    Fix: open each run and click Cancel workflow — a waiting/pending run"
  echo "    holds the deploy-${env_name} concurrency group forever (even when it runs"
  echo "    an older or deleted workflow version)."
fi
if [[ -n "$broken_label_runs" ]]; then
  echo "!! BLOCKING: runs with a broken single-label runs-on (pre-fromJSON bug):"
  printf "$broken_label_runs" | sed 's/^/       - run /'
  echo "    Fix: cancel them — no runner will ever match one comma-joined label."
fi
if [[ -n "$approval_pending" ]]; then
  echo "!! ACTION REQUIRED: environment approval pending on run ${approval_pending}"
  echo "    Fix: open the run, click 'Review deployments' -> Approve and deploy."
fi
if [[ -z "$stale_runs" && -z "$approval_pending" ]]; then
  echo "OK: no stale run, no pending approval."
fi
if [[ -n "$dead_runs" ]]; then
  echo "    (advisory) queued runs of deleted workflows never start; cancel to clean up:"
  printf "$dead_runs" | awk -F'\t' '{printf "       - run %s %s\n", $1, $2}'
fi
if [[ "$blocking" == true ]]; then exit 1; fi
exit 0
