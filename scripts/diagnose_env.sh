#!/usr/bin/env bash
# Diagnose a personal environment's deploy chain: the last /deploy pin on
# the deploy/<env> state branch -> pin-state -> deploy, plus the
# environment basics (GitHub env exists, runner label, state branch,
# pinned image). Personal envs are fed by /deploy on feature-branch PRs
# — there is no autopin from a per-user integration branch.
#
# Every check prints a FLAG line (machine-readable) and a human report;
# --flags prints only the FLAG lines (grep-able summary).
#
# Usage:
#   scripts/diagnose_env.sh <env>            # human report
#   scripts/diagnose_env.sh <env> --flags    # FLAG lines only
#
# Exit codes: 0 healthy or advisories only, 1 a blocking cause, 2 usage.

set -euo pipefail

usage="usage: diagnose_env.sh <env> [--flags]"
env_name="${1:?$usage}"
shift || true
flags_only=false
if [[ "${1:-}" == "--flags" ]]; then
  flags_only=true
elif [[ $# -gt 0 ]]; then
  echo "$usage" >&2
  exit 2
fi

repo_infra="jj-guild/botforge-infra"
env_branch="deploy/${env_name}"

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
  echo "==> Personal env diagnose: ${env_name} (state branch ${env_branch}, fed by /deploy pins)"
fi

# 1. The state branch exists and carries a pinned image.
state_pin="$(git ls-remote "https://github.com/${repo_infra}.git" "refs/heads/${env_branch}" 2>/dev/null | cut -f1 || true)"
if [[ -n "$state_pin" ]]; then
  pinned="$(gh api "repos/${repo_infra}/contents/envs/${env_name}/state/botforge-bot.yml?ref=${env_branch}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -E '^image:' | head -1 | cut -d' ' -f2- || true)"
  if [[ -n "$pinned" ]]; then
    flag OK "state branch ${env_branch} pins: ${pinned}"
  else
    flag BLOCK "state branch ${env_branch} has no pinned image (state file empty or missing)"
  fi
else
  flag WARN "state branch ${env_branch} not found — the first /deploy pin creates it via pin-state"
fi

# 2. The deploy ran on the state branch push and succeeded.
latest_deploy="$(gh api "repos/${repo_infra}/actions/runs?branch=${env_branch}&per_page=5" \
  --jq '[.workflow_runs[] | select(.name == "Deploy environment")][0] | {status, conclusion, html_url}' 2>/dev/null || true)"
if [[ -n "$latest_deploy" && "$latest_deploy" != "null" ]]; then
  d_status="$(printf '%s' "$latest_deploy" | jq -r '.status')"
  d_conclusion="$(printf '%s' "$latest_deploy" | jq -r '.conclusion // "none"')"
  if [[ "$d_status" == "completed" && "$d_conclusion" == "success" ]]; then
    flag OK "deploy succeeded on ${env_branch}"
  elif [[ "$d_status" == "completed" ]]; then
    flag BLOCK "deploy on ${env_branch} concluded: ${d_conclusion} — see scripts/diagnose_deploy.sh ${env_name}"
  else
    flag WARN "deploy on ${env_branch} still: ${d_status}"
  fi
else
  flag WARN "no Deploy environment run on ${env_branch} yet"
fi

# 3. The GitHub environment exists (secrets land on its runner).
gh_env="$(gh api "repos/${repo_infra}/environments" --paginate --jq \
  "[.environments[].name] | index(\"$env_name\") != null" 2>/dev/null || true)"
if [[ "$gh_env" == "true" ]]; then
  flag OK "GitHub environment '${env_name}' exists"
else
  flag BLOCK "GitHub environment '${env_name}' missing (Settings > Environments) — secrets cannot be injected"
fi

# 4. A runner answers the env-<env> label (the deploy job needs it).
# The runners API needs admin scope; without it the check is
# indeterminate (WARN, not BLOCK) — a queued deploy run already proves
# a runner answered, so a BLOCK here is only meaningful with API access.
runners="$(gh api "repos/${repo_infra}/actions/runners" --paginate \
  --jq "[.runners[] | select(.labels[].name == \"env-${env_name}\")] | length" 2>/dev/null || true)"
if [[ "$runners" =~ ^[0-9]+$ && "$runners" -gt 0 ]]; then
  flag OK "runner with label env-${env_name}: ${runners}"
elif [[ ! "$runners" =~ ^[0-9]+$ ]]; then
  flag WARN "runner list not readable with this token (admin scope needed) — check the latest deploy run instead"
else
  flag BLOCK "no runner with label env-${env_name} — the deploy job stays queued forever"
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
