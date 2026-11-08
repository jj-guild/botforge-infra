#!/usr/bin/env bash
# Back up the MongoDB and Redis data of a target environment.
# Produces:
#   <env>-<timestamp>.archive.gz   (MongoDB, mongodump --archive --gzip)
#   <env>-<timestamp>.rdb          (Redis, BGSAVE snapshot of the dataset)
# Both artifacts are verified before being accepted.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t ENVIRONMENTS < <(cd "${REPO_ROOT}/envs" && ls -d */ 2>/dev/null | tr -d '/')
[[ ${#ENVIRONMENTS[@]} -gt 0 ]] || { echo "ERROR: no environment found under envs/" >&2; exit 1; }
ENVIRONMENT="${1:-test}"
# The backup directory must survive repo checkouts: CD passes a
# persistent path via the BACKUP_DIR variable (VPS-SETUP.md).
BACKUP_DIR="${2:-${BACKUP_DIR:-${REPO_ROOT}/backups}}"
COMPOSE_FILE="${REPO_ROOT}/envs/${ENVIRONMENT}/docker-compose.yml"
MONGO_SERVICE="botforge-mongo"
REDIS_SERVICE="botforge-redis"

usage() {
    echo "Usage: $0 <${ENVIRONMENTS[*]}> [backup_dir]"
    exit 1
}

log() { echo "[backup:${ENVIRONMENT}] $*"; }

die() { echo "[backup:${ENVIRONMENT}] ERROR: $*" >&2; exit 1; }

[[ " ${ENVIRONMENTS[*]} " == *" ${ENVIRONMENT} "* ]] || usage
[[ -f "${COMPOSE_FILE}" ]] || die "missing compose file: ${COMPOSE_FILE}"

mkdir -p "${BACKUP_DIR}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MONGO_ARCHIVE="${BACKUP_DIR}/${ENVIRONMENT}-${TIMESTAMP}.archive.gz"
REDIS_DUMP="${BACKUP_DIR}/${ENVIRONMENT}-${TIMESTAMP}.rdb"
cd "$(dirname "${COMPOSE_FILE}")"

# --- MongoDB ---
log "dumping MongoDB to ${MONGO_ARCHIVE}"
if ! docker compose exec -T "${MONGO_SERVICE}" mongodump --archive --gzip >"${MONGO_ARCHIVE}"; then
    rm -f "${MONGO_ARCHIVE}"
    die "mongodump failed; removed partial archive"
fi
[[ -s "${MONGO_ARCHIVE}" ]] || { rm -f "${MONGO_ARCHIVE}"; die "MongoDB archive is empty; removed"; }
gzip -t "${MONGO_ARCHIVE}" || { rm -f "${MONGO_ARCHIVE}"; die "MongoDB archive is not valid gzip; removed"; }
log "MongoDB backup verified: ${MONGO_ARCHIVE} ($(du -h "${MONGO_ARCHIVE}" | cut -f1))"

# --- Redis ---
log "snapshotting Redis to ${REDIS_DUMP}"
# BGSAVE writes a consistent RDB snapshot without blocking the server;
# wait until the background save completes.
if ! docker compose exec -T "${REDIS_SERVICE}" sh -c '
    redis-cli BGSAVE >/dev/null
    until [ "$(redis-cli --raw INFO persistence | tr -d "\r" | awk -F: "/rdb_bgsave_in_progress/{print \$2}")" = "0" ]; do
        sleep 1
    done
'; then
    rm -f "${REDIS_DUMP}"
    # The Redis dataset is a CACHE (hot workflow state, TTLs) — its loss
    # degrades nothing durable; a BGSAVE failure (typically the host's
    # missing vm.overcommit_memory=1 starving the fork on a busy VPS)
    # must not block a deployment behind a mandatory backup. The Mongo
    # archive (the durable data) stays mandatory.
    log "WARNING: redis BGSAVE failed; continuing without the Redis snapshot (cache-only data)"
elif ! docker compose cp "${REDIS_SERVICE}:/data/dump.rdb" "${REDIS_DUMP}" 2>/dev/null \
        || [[ ! -s "${REDIS_DUMP}" ]]; then
    rm -f "${REDIS_DUMP}"
    log "WARNING: redis dump copy failed; continuing without it (cache-only data)"
else
    log "Redis backup verified: ${REDIS_DUMP} ($(du -h "${REDIS_DUMP}" | cut -f1))"
fi

log "backup complete: prefix ${ENVIRONMENT}-${TIMESTAMP}"
