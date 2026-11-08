#!/usr/bin/env bash
# Diagnose a personal environment's deploy chain (env test of the
# personal-env rollout): the vibe/<alias>/main push -> docker.yml build
# -> autopin -> pin-state -> deploy chain, plus the environment basics
# (GitHub env exists, runner label, state branch, pinned image).
#
# Every check prints a FLAG line (machine-readable) and a human report;
# --flags prints only the FLAG lines (grep-able summary).
#
# Usage:
#   scripts/diagnose_env.sh <alias>            # human report
#   scripts/diagnose_env.sh <alias> --flags    # FLAG lines only
#
# Exit codes: 0 healthy or advisories only, 1 a blocking cause, 2 usage.

set -euo pipefail

usage="usage: diagnose_env.sh <alias> [--flags]"
alias_name="${1:?$usage}"
shift || true
flags_only=false
if [[ "${1:-}" == "--flags" ]]; then
  flags_only=true
elif [[ $# -gt 0 ]]; then
  echo "$usage" >&2
  exit 2
fi

repo_infra="jj-guild/botforge-infra"
repo_svc="jj-guild/botforge-services"
env_branch="deploy/${alias_name}"
integration_branch="vibe/${alias_name}/main"

# Accumulated FLAG lines; exit 1 when any BLOCKING flag is raised.
flags=""
blocking=false
flag() { # flag <OK|WARN|BLOCK> <message>
  flags="${flags}FLAG [$1] $2\n"
  if [[ "$1" == "BLOCK" ]]; then blocking=true; fi
  if [[ "$flags_only" == true ]]; then return; fi
  case "$1" in
    OK)   echo "  OK   $2" ;;
    WARN) echo "  ?    $2" ;;
    BLOCK) echo "  !!   $2" ;;
  esac
}

if [[ "$flags_only" != true ]]; then
  echo "==> Personal env diagnose: ${alias_name} (${integration_branch} -> ${env_branch})"
fi

# 1. The integration branch exists and reports its head.
head_sha="$(git ls-remote "https://github.com/${repo_svc}.git" "refs/heads/${integration_branch}" 2>/dev/null | cut -f1 || true)"
if [[ -n "$head_sha" ]]; then
  flag OK "integration branch ${integration_branch} exists (head ${head_sha:0:7})"
else
  flag BLOCK "integration branch ${integration_branch} not found on ${repo_svc}"
fi

# 2. The docker.yml build ran (and succeeded) for that head.
if [[ -n "$head_sha" ]]; then
  build_run="$(gh api "repos/${repo_svc}/actions/runs?head_sha=${head_sha}&per_page=10" \
    --jq '[.workflow_runs[] | select(.name == "Docker") | select(.event == "push")][0] | {status, conclusion, html_url}' 2>/dev/null || true)"
  if [[ -n "$build_run" && "$build_run" != "null" ]]; then
    status="$(printf '%s' "$build_run" | jq -r '.status')"
    conclusion="$(printf '%s' "$build_run" | jq -r '.conclusion // "none"')"
    if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
      flag OK "docker.yml build succeeded for ${head_sha:0:7}"
    elif [[ "$status" == "completed" ]]; then
      flag BLOCK "docker.yml build for ${head_sha:0:7} concluded: ${conclusion} (no image, no autopin)"
    else
      flag WARN "docker.yml build for ${head_sha:0:7} still: ${status}"
    fi
  else
    flag WARN "no docker.yml run found for ${head_sha:0:7} — head predates the personal-env build (or the push did not trigger it)"
  fi
fi

# 3. The autopin job of that build run dispatched pin-state.
if [[ -n "${build_run:-}" && "$build_run" != "null" && "$(printf '%s' "$build_run" | jq -r '.html_url // empty')" != "" ]]; then
  run_id="$(printf '%s' "$build_run" | jq -r '.html_url' | grep -o '[0-9]*$')"
  autopin="$(gh api "repos/${repo_svc}/actions/runs/${run_id}/jobs" \
    --jq "[.jobs[] | select(.name | startswith(\"Autopin\")) | select(.conclusion == \"success\")][0] | if . == null then null else {status, conclusion} end" 2>/dev/null || true)"
  if [[ -n "$autopin" && "$autopin" != "null" ]]; then
    a_status="$(printf '%s' "$autopin" | jq -r '.status')"
    a_conclusion="$(printf '%s' "$autopin" | jq -r '.conclusion // "none"')"
    if [[ "$a_status" == "completed" && "$a_conclusion" == "success" ]]; then
      flag OK "autopin job succeeded (pin-state dispatched)"
    elif [[ "$a_status" == "completed" ]]; then
      flag BLOCK "autopin job concluded: ${a_conclusion} — check its log (App token, dispatch 422)"
    else
      flag WARN "autopin job still: ${a_status}"
    fi
  else
    flag BLOCK "no Autopin job on run ${run_id} — the ref does not match vibe/*/main"
  fi
fi

# 4. The state branch exists and carries a pinned image (matching the head).
state_pin="$(git ls-remote "https://github.com/${repo_infra}.git" "refs/heads/${env_branch}" 2>/dev/null | cut -f1 || true)"
if [[ -n "$state_pin" ]]; then
  pinned="$(gh api "repos/${repo_infra}/contents/envs/${alias_name}/state/botforge-bot.yml?ref=${env_branch}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -E '^image:' | head -1 | cut -d' ' -f2- || true)"
  if [[ -n "$pinned" ]]; then
    flag OK "state branch ${env_branch} pins: ${pinned}"
    if [[ -n "$head_sha" && "$pinned" == *"${head_sha:0:7}"* ]]; then
      flag OK "pinned image matches the integration branch head (${head_sha:0:7})"
    elif [[ -n "$head_sha" ]]; then
      flag WARN "pinned image does not match the head ${head_sha:0:7} — pin not yet written or older"
    fi
  else
    flag BLOCK "state branch ${env_branch} has no pinned image (state file empty or missing)"
  fi
else
  flag WARN "state branch ${env_branch} not found — first autopin will create it via pin-state"
fi

# 5. The deploy ran on the state branch push and succeeded.
latest_deploy="$(gh api "repos/${repo_infra}/actions/runs?branch=${env_branch}&per_page=5" \
  --jq '[.workflow_runs[] | select(.name == "Deploy environment")][0] | {status, conclusion, html_url}' 2>/dev/null || true)"
if [[ -n "$latest_deploy" && "$latest_deploy" != "null" ]]; then
  d_status="$(printf '%s' "$latest_deploy" | jq -r '.status')"
  d_conclusion="$(printf '%s' "$latest_deploy" | jq -r '.conclusion // "none"')"
  if [[ "$d_status" == "completed" && "$d_conclusion" == "success" ]]; then
    flag OK "deploy succeeded on ${env_branch}"
  elif [[ "$d_status" == "completed" ]]; then
    flag BLOCK "deploy on ${env_branch} concluded: ${d_conclusion} — see scripts/diagnose_deploy.sh ${alias_name}"
  else
    flag WARN "deploy on ${env_branch} still: ${d_status}"
  fi
else
  flag WARN "no Deploy environment run on ${env_branch} yet"
fi

# 6. The GitHub environment exists (secrets land on its runner).
gh_env="$(gh api "repos/${repo_infra}/environments" --paginate --jq \
  "[.environments[].name] | index(\"$alias_name\") != null" 2>/dev/null || true)"
if [[ "$gh_env" == "true" ]]; then
  flag OK "GitHub environment '${alias_name}' exists"
else
  flag BLOCK "GitHub environment '${alias_name}' missing (Settings > Environments) — secrets cannot be injected"
fi

# 7. A runner answers the env-<alias> label (the deploy job needs it).
# The runners API needs admin scope; without it the check is
# indeterminate (WARN, not BLOCK) — a queued deploy run already proves
# a runner answered, so a BLOCK here is only meaningful with API access.
runners="$(gh api "repos/${repo_infra}/actions/runners" --paginate \
  --jq "[.runners[] | select(.labels[].name == \"env-${alias_name}\")] | length" 2>/dev/null || true)"
if [[ "$runners" =~ ^[0-9]+$ && "$runners" -gt 0 ]]; then
  flag OK "runner with label env-${alias_name}: ${runners}"
elif [[ ! "$runners" =~ ^[0-9]+$ ]]; then
  flag WARN "runner list not readable with this token (admin scope needed) — check the latest deploy run instead"
else
  flag BLOCK "no runner with label env-${alias_name} — the deploy job stays queued forever"
fi

if [[ "$flags_only" == true ]]; then
  printf "$flags"
fi
if [[ "$blocking" == true ]]; then
  if [[ "$flags_only" != true ]]; then echo "Diagnosis: BLOCKING flags raised."; fi
  exit 1
fi
if [[ "$flags_only" != true ]]; then echo "Diagnosis: no blocking flag."; fi
exit 0
