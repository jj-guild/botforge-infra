#!/usr/bin/env bash
# Clean the Docker resources of an environment's runner VPS (env cleanup).
#
# The test-env VPS accumulate Docker residue: dangling images from
# interrupted builds, stopped containers of old deploys, orphaned
# networks/volumes, build cache. Eventually the disk fills and the
# runner itself fails ("No space left on device" on its own _diag log).
#
# Two modes (docker-clean.yml):
#   prune (default) — SAFE: dangling images, stopped containers,
#     unused networks and build cache only. Anything a running (or
#     stopped-but-pinned) environment still references is untouched.
#   deep — EVERYTHING unused: docker system prune -af --volumes.
#     Frees the most space; a stopped env's images come back on its
#     next deploy (the pin pulls them). Volumes of running containers
#     are never touched (prune only removes UNUSED volumes).
#
# Refuses prod-style environments: the prod runner's residue is an ops
# decision, never a cleanup side effect.
set -euo pipefail

ENVIRONMENT="${1:?usage: docker_clean.sh <environment> [prune|deep]}"
MODE="${2:-prune}"
RUNNER_ROOT="${RUNNER_ROOT:-/opt/botforge/runners}"

if [[ "${ENVIRONMENT}" == "prod" ]]; then
  echo "::error::docker clean is never allowed on prod (ops decision, never a side effect)"
  exit 1
fi

if [[ ! -d "${RUNNER_ROOT}/${ENVIRONMENT}" ]]; then
  echo "::error::no runner for env ${ENVIRONMENT} under ${RUNNER_ROOT}"
  exit 1
fi

df_report() {
  df -h / | tail -1 | awk '{print "disk: " $3 " used, " $4 " free (" $5 " on " $6 ")"}'
}

echo "=== docker clean: ${ENVIRONMENT} (mode: ${MODE}) ==="
echo "--- before ---"
df_report
docker system df || true

echo "--- cleaning ---"
if [[ "${MODE}" == "deep" ]]; then
  # Everything unused, volumes included (unused = not referenced by ANY
  # container, running or stopped: the running envs are safe).
  docker system prune -af --volumes
else
  docker container prune -f
  docker image prune -f
  docker network prune -f
  docker builder prune -af
fi

echo "--- after ---"
df_report
docker system df || true
