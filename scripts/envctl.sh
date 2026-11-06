#!/usr/bin/env bash
# Control the Kingdoms stack of a target environment (test, prod):
# start | stop | restart | status | reset. Runs ON the environment's
# runner (called by .github/workflows/env-control.yml) and dumps the
# result; it never deploys, never pulls, never touches the pinned state.
#
# reset stops the stack and recreates it fresh — the DATA SURVIVES:
# mongo and redis ride bind mounts on the VPS filesystem
# (/opt/kingdoms/envs/<env>/{mongo,redis}), never docker volumes, so a
# reset (docker compose down --volumes) nor any volume prune can wipe
# them. Double gate before it can run:
#   1. the env-reset roster capability (self env only; ops anywhere),
#   2. the env itself opts in: x-kingdoms-env-resettable: true in its
#      compose manifest (an allowlist — prod never carries the flag, and
#      a new environment without it fails closed).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t ENVIRONMENTS < <(cd "${REPO_ROOT}/envs" && ls -d */ 2>/dev/null | tr -d '/')
[[ ${#ENVIRONMENTS[@]} -gt 0 ]] || { echo "ERROR: no environment found under envs/" >&2; exit 1; }
COMMANDS=(start stop restart status reset wipe-liquipedia-cache)

ENVIRONMENT="${1:-}"
COMMAND="${2:-}"

usage() {
    echo "Usage: $0 <${ENVIRONMENTS[*]}> <${COMMANDS[*]}>"
    exit 1
}

log() { echo "[envctl:${ENVIRONMENT}] $*"; }
die() { echo "[envctl:${ENVIRONMENT}] ERROR: $*" >&2; exit 1; }

[[ " ${ENVIRONMENTS[*]} " == *" ${ENVIRONMENT} "* ]] || usage
[[ " ${COMMANDS[*]} " == *" ${COMMAND} "* ]] || usage

COMPOSE_FILE="${REPO_ROOT}/envs/${ENVIRONMENT}/docker-compose.yml"
[[ -f "${COMPOSE_FILE}" ]] || die "missing compose file: ${COMPOSE_FILE}"

# Same substitution inputs as deploy.sh: the pinned image comes from the
# state file (compose fails closed without it), DISCORD_TOKEN from the
# GitHub environment secrets. Control commands never change the state.
STATE_FILE="${REPO_ROOT}/envs/${ENVIRONMENT}/state/kingdoms-bot.yml"
if [[ -f "${STATE_FILE}" ]]; then
    pinned_image="$(grep -E '^image:' "${STATE_FILE}" | head -1 | cut -d' ' -f2-)"
    [[ -n "${pinned_image:-}" ]] || die "state file ${STATE_FILE} has no image"
    export KINGDOMS_BOT_IMAGE="${pinned_image}"
fi
[[ -n "${DISCORD_TOKEN:-}" ]] \
    || die "DISCORD_TOKEN is not set (provide it via the GitHub environment secrets)"

cd "${REPO_ROOT}/envs/${ENVIRONMENT}"

case "${COMMAND}" in
    start)
        log "starting the stack (no pull, no recreate)"
        docker compose start
        ;;
    stop)
        log "stopping the stack"
        docker compose stop
        ;;
    restart)
        log "restarting the stack (no pull, no recreate)"
        docker compose restart
        ;;
    wipe-liquipedia-cache)
        # SURGICAL cache wipe (owner direction 2026-11-06): the liquipedia
        # provider's own tables carry descriptors fetched by the buggy-era
        # pipeline (missing images/traits). The wipe drops ONLY those two
        # collections — the next maps sync re-fetches everything fresh
        # through the current pipeline. No other data is touched.
        log "WIPING the liquipedia cache tables (liquipedia_maps, liquipedia_pages)"
        docker compose exec -T kingdoms-mongo mongosh --quiet --eval '
            const db = db.getSiblingDB("kingdoms");
            const maps = db.getCollection("liquipedia_maps").drop();
            const pages = db.getCollection("liquipedia_pages").drop();
            print("liquipedia_maps dropped: " + maps + ", liquipedia_pages dropped: " + pages);
        '
        ;;
    reset)
        # Allowlist: only manifests carrying x-kingdoms-env-resettable: true.
        # Read the flag from the compose FILE, not from `docker compose config`:
        # the config output strips top-level x- extension fields (compose-spec),
        # so the flag is invisible there (the 2026-10-15 /reset-env failure).
        resettable="$(python3 -c '
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}
print(data.get("x-kingdoms-env-resettable") is True)
' "${COMPOSE_FILE}")"
        [[ "$resettable" == "True" ]] \
            || die "reset is not allowed on this environment (no x-kingdoms-env-resettable flag in its compose manifest)"
        log "RESETTING: stopping the stack (the externalized data under /opt/kingdoms/envs/${ENVIRONMENT} survives)"
        docker compose down --volumes
        ;;
    status)
        log "stack status"
        ;;
esac

echo
echo "=== docker compose ps ==="
docker compose ps
echo
log "done (${COMMAND})"
