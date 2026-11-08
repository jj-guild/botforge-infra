#!/usr/bin/env bash
# Deploy the BotForge stack to a target environment (test, prod).
# Idempotent, with mandatory pre-deploy backup and post-deploy health gate.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t ENVIRONMENTS < <(cd "${REPO_ROOT}/envs" && ls -d */ 2>/dev/null | tr -d '/')
[[ ${#ENVIRONMENTS[@]} -gt 0 ]] || { echo "ERROR: no environment found under envs/" >&2; exit 1; }
ENVIRONMENT="${1:-test}"
ENV_DIR="${REPO_ROOT}/envs/${ENVIRONMENT}"
COMPOSE_FILE="${ENV_DIR}/docker-compose.yml"
MONGO_SERVICE="botforge-mongo"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"

usage() {
    echo "Usage: $0 <${ENVIRONMENTS[*]}>"
    exit 1
}

log() { echo "[deploy:${ENVIRONMENT}] $*"; }

die() { echo "[deploy:${ENVIRONMENT}] ERROR: $*" >&2; exit 1; }

[[ " ${ENVIRONMENTS[*]} " == *" ${ENVIRONMENT} "* ]] || usage
[[ -f "${COMPOSE_FILE}" ]] || die "missing compose file: ${COMPOSE_FILE}"

# Secrets come from the CD pipeline environment (GitHub environment
# secrets); nothing secret is stored on the VPS. Compose substitution
# fails closed on a missing DISCORD_TOKEN.
[[ -n "${DISCORD_TOKEN:-}" ]] \
    || die "DISCORD_TOKEN is not set (provide it via the GitHub environment secrets)"

# Desired state (ADR-0018): when a state file exists in this checkout,
# it is the source of truth for the deployed image and deploy URL —
# the deploy workflow checks out the state branch commit, so the
# pinned values cannot drift or be spoofed via workflow inputs.
STATE_FILE="${REPO_ROOT}/envs/${ENVIRONMENT}/state/botforge-bot.yml"
if [[ -f "${STATE_FILE}" ]]; then
    pinned_image="$(grep -E '^image:' "${STATE_FILE}" | head -1 | cut -d' ' -f2-)"
    pinned_url="$(grep -E '^deploy_url:' "${STATE_FILE}" | head -1 | cut -d' ' -f2-)"
    pinned_label="$(grep -E '^version_label:' "${STATE_FILE}" | head -1 | cut -d' ' -f2-)"
    [[ -n "${pinned_image:-}" ]] || die "state file ${STATE_FILE} has no image"
    export BOTFORGE_IMAGE="${pinned_image}"
    [[ -n "${pinned_url:-}" ]] || pinned_url=""
    export BOTFORGE_DEPLOY_URL="${pinned_url}"
    # The pinned image reference is also exposed to the bot so /status can
    # link the exact running container image (BOTFORGE_DEPLOY_IMAGE).
    export BOTFORGE_DEPLOY_IMAGE="${pinned_image}"
    [[ -n "${pinned_label:-}" ]] || pinned_label=""
    export BOTFORGE_DEPLOY_LABEL="${pinned_label}"
    # Typed /status links (botforge-services#81): deploy kind, ref, tree and
    # timestamp, written by the pipelines alongside the pinned image.
    for field in kind ref tree_url ts commit_ts branch pr_title commit ci_run_id ci_run_number ci_run_ts; do
        value="$(grep -E "^deploy_${field}:" "${STATE_FILE}" | head -1 | cut -d' ' -f2- || true)"
        export "BOTFORGE_DEPLOY_${field^^}"="${value}"
    done
    log "state: image=${BOTFORGE_IMAGE} label=${BOTFORGE_DEPLOY_LABEL:-<none>} deploy_url=${BOTFORGE_DEPLOY_URL:-<none>} kind=${BOTFORGE_DEPLOY_KIND:-<none>} ref=${BOTFORGE_DEPLOY_REF:-<none>}"
fi

# Every process (bot, core, ext, game) logs its version at startup; the
# running version is the deployed image tag (ADR-0018 pinned reference).
if [[ -n "${BOTFORGE_IMAGE:-}" ]]; then
    export BOTFORGE_VERSION="${BOTFORGE_IMAGE##*:}"
    log "version: ${BOTFORGE_VERSION}"
fi

cd "${ENV_DIR}"

# Idempotence note: this script manages the full stack lifecycle. Running
# `docker compose pull` before `up` is safe: it only refreshes images.

log "pulling images"
docker compose pull --quiet

# Resolve the pulled image digest and expose tag@digest to the bot:
# /status and the boot announcement render the exact running image
# (BOTFORGE_DEPLOY_IMAGE), not just its mutable tag (ADR-0018).
if [[ -n "${BOTFORGE_IMAGE:-}" ]]; then
    image_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${BOTFORGE_IMAGE}" 2>/dev/null || true)"
    if [[ "${image_digest}" == *"@sha256:"* ]]; then
        digest="${image_digest##*@}"
        tag="${BOTFORGE_IMAGE##*:}"
        export BOTFORGE_DEPLOY_IMAGE="${tag}@${digest}"
        log "image resolved to ${BOTFORGE_DEPLOY_IMAGE}"
    else
        log "image digest not resolvable; /status shows the pinned tag"
    fi
fi

# Mandatory backup before any deployment — except the very first one:
# on a fresh VPS the stack does not exist yet, so there is nothing to
# back up (backup_db.sh fails closed on a non-running MongoDB).
#
# A mongo that compose still lists as running but does NOT answer
# (crash-looped mongod, broken docker-network DNS — merlin 2026-10-29)
# must never deadlock the deploy: the backup fails, the stack is
# re-converged (compose up restarts the store and its network), and the
# backup retries once. Only a failure AFTER the converge aborts.
if docker compose config --services >/dev/null 2>&1 \
    && docker compose ps --status running --format json 2>/dev/null \
        | grep -q "${MONGO_SERVICE}"; then
    log "running mandatory pre-deploy backup"
    if ! "${REPO_ROOT}/scripts/backup_db.sh" "${ENVIRONMENT}"; then
        log "backup failed — the store is down but compose thinks it runs"
        log "re-converging the stack first (restarts mongo + its network)"
        docker compose up -d --remove-orphans "${MONGO_SERVICE}" \
            || die "pre-deploy stack converge failed: aborting deployment"
        MONGO_DEADLINE=$(( $(date +%s) + 90 ))
        until docker compose ps --format json "${MONGO_SERVICE}" 2>/dev/null \
            | grep -q '"Health":"healthy"'; do
            if (( $(date +%s) > MONGO_DEADLINE )); then
                die "mongo did not come back healthy after the converge"
            fi
            sleep 3
        done
        log "retrying the pre-deploy backup once"
        "${REPO_ROOT}/scripts/backup_db.sh" "${ENVIRONMENT}" \
            || die "pre-deploy backup failed after the stack converge: aborting"
    fi
else
    log "stack not running yet (first deployment?): skipping the backup"
fi

# One-shot data migration (externalized volumes): the stores ride bind
# mounts on the VPS filesystem (/opt/botforge/envs/<env>/{mongo,redis})
# — the data survives reset-env, volume prunes and compose down -v.
# The FIRST deploy after the switch must carry the legacy named volumes'
# content over: with the stack stopped (a stopped mongod flushes its
# files — a live file copy would corrupt WiredTiger), the copy is safe.
# Runs only when the legacy volume exists AND the target dir is empty.
DATA_ROOT="/opt/botforge/envs/${ENVIRONMENT}"
_migrate_store() {
    local name="$1" dir="$2"
    mkdir -p "${dir}"
    if docker volume inspect "${ENVIRONMENT}_${name}" >/dev/null 2>&1         && [[ -z "$(ls -A "${dir}" 2>/dev/null)" ]]; then
        log "migrating ${ENVIRONMENT}_${name} -> ${dir} (one-shot, stack stopped)"
        docker run --rm \
            -v "${ENVIRONMENT}_${name}:/source:ro" \
            -v "${dir}:/target" \
            alpine:3 cp -a /source/. /target/ \
            || die "store migration failed for ${name}: aborting (the legacy volume is untouched)"
        log "migration done: ${dir} now holds ${name}'s data (legacy volume kept until cleaned)"
    fi
}
docker compose stop botforge-mongo botforge-redis >/dev/null 2>&1 || true
_migrate_store mongo_data "${DATA_ROOT}/mongo"
_migrate_store redis_data "${DATA_ROOT}/redis"

log "applying the stack"
# ADR-0020 process split (botforge-infra#89): the stack is now four
# BotForge processes (bot, core, ext-librematch, ext-aoe2lobby) plus the
# stores. `up` is still one atomic converge: compose starts the
# dependencies first (depends_on service_healthy), so core comes up
# before the bot and the providers; the health gate below then verifies
# every declared service. Rollback stays per-pin (one image backs the
# four processes), applied by scripts/rollback.sh as before.
docker compose up -d --remove-orphans

log "waiting for services to become healthy (${HEALTH_TIMEOUT}s)"
DEADLINE=$(( $(date +%s) + HEALTH_TIMEOUT ))
# Every service in the manifest is gated: the manifest is the source of
# truth, a service added later is gated without touching this script.
# Order matters for the gate only (core before bot reads better in logs);
# startup order itself is enforced by depends_on.
for service in $(docker compose config --services | sort); do
    if ! docker compose ps --format json "${service}" 2>/dev/null \
        | grep -q '"Health"'; then
        # A service without a healthcheck (none today, but the manifest is
        # data) passes on the running state instead of blocking the gate.
        if docker compose ps --status running --format json "${service}" 2>/dev/null \
            | grep -q '"${service}"'; then
            log "service ${service} is running (no healthcheck declared)"
            continue
        fi
    fi
    until docker compose ps --format json "${service}" 2>/dev/null \
        | grep -q '"Health":"healthy"'; do
        if (( $(date +%s) > DEADLINE )); then
            log "service ${service} failed to become healthy; rolling back"
            "${REPO_ROOT}/scripts/rollback.sh" "${ENVIRONMENT}" --auto || true
            die "service ${service} unhealthy after ${HEALTH_TIMEOUT}s"
        fi
        sleep 3
    done
    log "service ${service} is healthy"
done

log "deployment to '${ENVIRONMENT}' applied and healthy"
