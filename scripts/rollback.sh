#!/usr/bin/env bash
# Roll back the BotForge stack to its last known-good state.
#
# Two paths (ADR-0018, the state is the source of truth):
#
# - automatic (called by deploy.sh after a failed health gate): re-apply the
#   previous pinned state — the stack keeps running the last known-good
#   image without touching any data. The state-branch revert runs only
#   where the state branch accepts a direct push from the deploy pipeline
#   (deploy/test); on prod the push is blocked by the "Deploy PROD" ruleset
#   (required PR), so the automatic path restores the latest DB backup
#   instead and flags the incident loudly.
#
# - manual (operator-run): restore the most recent backup (or a given
#   archive) on top of the state revert.
#
# The automatic path never reverts code on main and never touches any
# repository other than this one — a rejected deployment rolls the pinned
# state back, not the source (the accidental revert of a docs commit taught
# us that).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t ENVIRONMENTS < <(cd "${REPO_ROOT}/envs" && ls -d */ 2>/dev/null | tr -d '/')
[[ ${#ENVIRONMENTS[@]} -gt 0 ]] || { echo "ERROR: no environment found under envs/" >&2; exit 1; }
ENVIRONMENT="${1:-test}"
shift || true
usage() {
    echo "Usage: $0 <${ENVIRONMENTS[*]}> [archive.gz] [--auto|--yes]"
    echo "  BACKUP_DIR=<dir> overrides the backup directory (default: <repo>/backups)."
    echo "  Without an archive, restores the most recent backup of the environment."
    echo "  --auto is the deploy.sh recovery path: re-apply the previous pinned"
    echo "  state (no data restore) where the state branch accepts a direct push."
    echo "  --yes restores a backup without the interactive confirmation (CI)."
    exit 1
}

MODE=""
for arg in "$@"; do
    case "${arg}" in
        --auto|--yes) MODE="${arg}" ;;
        *) if [[ -n "${ARCHIVE:-}" ]]; then usage; fi; ARCHIVE="${arg}" ;;
    esac
done
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"
STATE_FILE="envs/${ENVIRONMENT}/state/botforge-bot.yml"


log() { echo "[rollback:${ENVIRONMENT}] $*"; }
warn() { echo "::warning::[rollback:${ENVIRONMENT}] $*" >&2; }
die() { echo "[rollback:${ENVIRONMENT}] ERROR: $*" >&2; exit 1; }

[[ " ${ENVIRONMENTS[*]} " == *" ${ENVIRONMENT} "* ]] || usage

reapply_previous_state() {
    # The checkout is the state branch commit that deploy.sh just failed to
    # apply; the parent commit carries the previous known-good pin. Revert
    # the pin commit and push it back to the state branch: the push itself
    # re-triggers the deploy workflow, which re-applies the previous image
    # through the normal path.
    if ! command -v git >/dev/null 2>&1 \
        || ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "no git available; skipping the state revert"
        return 1
    fi
    if [[ -z "${ROLLBACK_TOKEN:-}" ]]; then
        log "no ROLLBACK_TOKEN in the environment; skipping the state revert"
        return 1
    fi
    local pin_sha
    pin_sha="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    if ! git -C "${REPO_ROOT}" show -s --format=%P HEAD | grep -q ' '; then
        warn "HEAD ${pin_sha} has no parent: nothing to revert to on ${ENVIRONMENT}"
        return 1
    fi
    if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain -- "${STATE_FILE}")" ]]; then
        warn "the state file has uncommitted changes; refusing to guess a revert"
        return 1
    fi
    if ! git -C "${REPO_ROOT}" revert --no-edit HEAD >/dev/null 2>&1; then
        warn "git revert of the pin commit ${pin_sha} failed"
        return 1
    fi
    git -C "${REPO_ROOT}" remote set-url origin \
        "https://x-access-token:${ROLLBACK_TOKEN}@github.com/jj-guild/botforge-infra.git"
    if ! git -C "${REPO_ROOT}" push origin "HEAD:deploy/${ENVIRONMENT}" 2>/dev/null; then
        # Non-fast-forward (the ruleset forbids it) or a rejection: put the
        # working tree back and fall through to the caller's fallback.
        git -C "${REPO_ROOT}" reset --hard "${pin_sha}" >/dev/null
        warn "push of the revert to deploy/${ENVIRONMENT} rejected"
        return 1
    fi
    log "pin reverted on deploy/${ENVIRONMENT}: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) restores the previous image"
    return 0
}

if [[ "${MODE}" == "--auto" ]]; then
    # Automatic recovery of a failed health gate: state first, data last.
    if reapply_previous_state; then
        log "rollback complete (previous pinned state re-applied; no data restore)"
        exit 0
    fi
    # Prod: the state branch requires a PR (ruleset); a direct push is
    # rejected by design. Restore the latest backup so the stack runs
    # *something* known-good and flag the incident for a human decision.
    warn "state revert unavailable on ${ENVIRONMENT}: restoring the latest backup instead"
    LATEST="$(ls -1t "${BACKUP_DIR}/${ENVIRONMENT}-"*.archive.gz 2>/dev/null | head -n 1 || true)"
    [[ -n "${LATEST}" ]] || die "no backup found in ${BACKUP_DIR}; nothing to roll back to"
    "${REPO_ROOT}/scripts/restore_db.sh" "${ENVIRONMENT}" "${LATEST}" --yes
    die "rollback incomplete: the pinned state on deploy/${ENVIRONMENT} still carries the failed image — open a revert PR (the rollback workflow) or re-pin manually"
fi

if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
    if [[ -n "${ARCHIVE}" ]]; then
        die "archive not found: ${ARCHIVE}"
    fi
    LATEST="$(ls -1t "${BACKUP_DIR}/${ENVIRONMENT}-"*.archive.gz 2>/dev/null | head -n 1 || true)"
    [[ -n "${LATEST}" ]] || die "no backup found in ${BACKUP_DIR}; nothing to roll back to"
    ARCHIVE="${LATEST}"
fi

log "rolling back to ${ARCHIVE}"

if [[ "${MODE}" != "--yes" ]]; then
    echo "This overwrites the current state of '${ENVIRONMENT}'."
    read -r -p "Continue? [y/N] " answer
    [[ "${answer}" == "y" || "${answer}" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

"${REPO_ROOT}/scripts/restore_db.sh" "${ENVIRONMENT}" "${ARCHIVE}" --yes

log "rollback complete"
