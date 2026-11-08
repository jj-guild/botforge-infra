#!/usr/bin/env bash
# Post-deploy battery (botforge-infra#78): verify the environment runs
# what the pinned state says. Read-only, Docker/API only, no test
# tooling on the env runner (hard constraint of #78).
#
# Severity semantics — the false-negative trap:
#   P0 confirmed broken deployment (wrong/missing identity) -> exit 10,
#       the caller (deploy-env.yml) triggers the automatic rollback.
#   P2 inconclusive/unreachable checks (Discord 5xx, missing config)
#       -> exit 0, reported only. Never roll back an unproven state.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-test}"
ENV_DIR="${REPO_ROOT}/envs/${ENVIRONMENT}"
STATE_FILE="${ENV_DIR}/state/botforge-bot.yml"
REPORT_FILE="${BATTERY_REPORT:-/tmp/battery-report.md}"

# Container names are compose-owned (`<project>-<service>-1`, the project is
# the env directory name — same default deploy.sh relies on by cd'ing into
# the env dir): never inspect a service by a literal container name, the
# name is not stable. Resolve the container id through compose instead.
compose() { docker compose --project-directory "${ENV_DIR}" "$@"; }
container_of() { compose ps -q "$1" 2>/dev/null || true; }

log() { echo "[battery:${ENVIRONMENT}] $*"; }

[[ -f "${STATE_FILE}" ]] || { echo "P0: state file missing: ${STATE_FILE}" >&2; exit 10; }

pinned_image="$(grep -E '^image:' "${STATE_FILE}" | head -1 | cut -d' ' -f2-)"
[[ -n "${pinned_image}" ]] || { echo "P0: state file has no pinned image" >&2; exit 10; }

# The compose file interpolates ${BOTFORGE_IMAGE:?}: without it exported
# every `compose ps` dies before listing containers and every check turns
# into a false P0. Export the pin — the same read deploy.sh does.
export BOTFORGE_IMAGE="${pinned_image}"

: > "${REPORT_FILE}"
echo "## Post-deploy battery — ${ENVIRONMENT}" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"

p0=0
p2=0

note() { echo "$*" >> "${REPORT_FILE}"; }
p0_found() { note "- **P0** $*"; p0=$((p0+1)); log "P0: $*"; }
p2_found() { note "- **P2** $*"; p2=$((p2+1)); log "P2: $*"; }
ok() { note "- OK: $*"; log "OK: $*"; }

# ── Check 1: stack identity — the running bot image matches the pin ──
bot_cid="$(container_of botforge-bot)"
running_image=""
if [[ -n "${bot_cid}" ]]; then
    running_image="$(docker inspect --format '{{.Config.Image}}' "${bot_cid}" 2>/dev/null || true)"
fi
if [[ -z "${running_image}" ]]; then
    p0_found "bot container not found (botforge-bot) — the stack did not come up"
elif [[ "${running_image}" != "${pinned_image}" ]]; then
    p0_found "running image ${running_image} != pinned ${pinned_image}"
else
    ok "stack identity: running image matches the pinned state (${pinned_image})"
fi

# Every declared service healthy (the deploy gate re-checked, cheap here).
for service in $(compose config --services 2>/dev/null | sort); do
    cid="$(container_of "${service}")"
    if [[ -z "${cid}" ]]; then
        p0_found "service ${service} has no running container"
        continue
    fi
    health="$(docker inspect --format '{{.State.Health.Status}}' "${cid}" 2>/dev/null || echo "")"
    if [[ -z "${health}" ]]; then
        p2_found "service ${service} reports no health status (may still be converging)"
    elif [[ "${health}" != "healthy" ]]; then
        p2_found "service ${service} reports health '${health}' (may still be converging)"
    else
        ok "service ${service} healthy"
    fi
done

# ── Check 2: command registration (Discord REST, read-only) ──
# The app id is the first section of the bot token (documented Discord
# invariant); no extra variable needed. Inconclusive API states are P2,
# never P0 — no rollback on an unproven state.
if [[ -n "${DISCORD_TOKEN:-}" ]]; then
    app_id="$(echo "${DISCORD_TOKEN}" | cut -d'.' -f1 | tr '_-' '/+' | base64 -d 2>/dev/null || true)"
    if [[ -n "${app_id}" ]]; then
        for _attempt in 1 2 3 4 5; do
            http_code="$(curl -s -o /tmp/commands.json -w '%{http_code}' \
                -H "Authorization: Bot ${DISCORD_TOKEN}" \
                "https://discord.com/api/v10/applications/${app_id}/commands" || echo 000)"
            case "${http_code}" in
                200) break ;;
                429|5*) sleep 5 ;;
                000) sleep 5 ;;
                *) break ;;
            esac
        done
        if [[ "${http_code}" == "200" ]]; then
            count="$(grep -c '"name"' /tmp/commands.json || echo 0)"
            if (( count > 0 )); then
                ok "command registration: ${count} global commands registered"
            else
                p2_found "command registration: empty command list (registration is eventually consistent)"
            fi
        else
            p2_found "command registration: inconclusive (Discord API HTTP ${http_code}) — no rollback on an unproven state"
        fi
    else
        p2_found "command registration: could not derive the application id from the token"
    fi
else
    p2_found "command registration: DISCORD_TOKEN not set in the battery step"
fi

echo "" >> "${REPORT_FILE}"
echo "**Verdict:** $(( p0 == 0 ? 1 : 0 )) (1 = deployment confirmed, 0 = P0 rollback)" >> "${REPORT_FILE}"

if (( p0 > 0 )); then
    log "confirmed-broken deployment (P0): rolling back"
    exit 10
fi
log "deployment confirmed (P2 findings: ${p2})"
exit 0
