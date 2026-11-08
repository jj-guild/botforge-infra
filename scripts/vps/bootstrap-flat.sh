#!/usr/bin/env bash
# BotForge VPS bootstrap — FLAT fallback for providers whose UI has no
# cloud-init user-data field (e.g. OVH reinstall window). Run as root over SSH:
#   curl -fsSL https://raw.githubusercontent.com/jj-guild/botforge-infra/main/scripts/vps/bootstrap-flat.sh | sudo bash
# Generated from docs/VPS-SETUP.md §1 cloud-init block — keep in sync.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl jq ufw

install -m 0755 -d "$(dirname "/opt/botforge/bin/bootstrap.sh")"
cat > "/opt/botforge/bin/bootstrap.sh" <<'__BOTFORGE_EOF__'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Docker Engine + Compose plugin (official repo, distro-adaptive) ---
install -m 0755 -d /etc/apt/keyrings
DISTRO_ID="$(. /etc/os-release && echo "${ID:-debian}")"   # debian | ubuntu
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# --- service user: no password, no sudo, in the docker group ---
id botforge >/dev/null 2>&1 || adduser --disabled-password --gecos "" botforge
usermod -aG docker botforge

# --- firewall: SSH only (the stack exposes no public port) ---
ufw allow OpenSSH
ufw --force enable

# --- multi-env filesystem layout ---
mkdir -p /opt/botforge/bin /opt/botforge/backups /opt/botforge/runners /opt/botforge/envs
chown -R botforge:botforge /opt/botforge

# --- pinned runner binary, downloaded ONCE, shared by every env ---
RUNNER_VERSION="2.337.0"  # <- version shown on the Runners page
echo "$RUNNER_VERSION" > /opt/botforge/runners/.runner-version
curl -fsSLo "/opt/botforge/runners/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
chown -R botforge:botforge /opt/botforge/runners
__BOTFORGE_EOF__
chmod 0755 "/opt/botforge/bin/bootstrap.sh"

install -m 0755 -d "$(dirname "/opt/botforge/bin/install-runner.sh")"
cat > "/opt/botforge/bin/install-runner.sh" <<'__BOTFORGE_EOF__'
#!/usr/bin/env bash
# Register one self-hosted runner for <env> and install it as a
# systemd service. Run as root:
#   install-runner.sh <env> --token <REGISTRATION_TOKEN> [--url https://github.com/ORG/botforge-infra]
set -Eeuo pipefail
ENV_NAME="${1:?usage: install-runner.sh <env> --token <REGISTRATION_TOKEN> [--url <repo-url>]}"
shift
TOKEN="" URL="https://github.com/jj-guild/botforge-infra"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:?}"; shift 2 ;;
    --url)   URL="${2:?}";   shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TOKEN" ]] || { echo "ERROR: --token required (Runners page, valid 1h)" >&2; exit 1; }
[[ "$ENV_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid env name '$ENV_NAME'" >&2; exit 1; }
RDIR="/opt/botforge/runners/$ENV_NAME"
[[ ! -d "$RDIR" ]] || { echo "ERROR: $RDIR already exists (env '$ENV_NAME' already installed)" >&2; exit 1; }

RUNNER_VERSION="$(cat /opt/botforge/runners/.runner-version)"
TARBALL="/opt/botforge/runners/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
[[ -f "$TARBALL" ]] || curl -fsSLo "$TARBALL" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

mkdir -p "$RDIR"
chown -R botforge:botforge "$RDIR"
sudo -iu botforge bash -c "cd '$RDIR' && tar xzf '$TARBALL' && ./config.sh --url '$URL' --token '$TOKEN' --labels 'botforge,env-$ENV_NAME'"
cd "$RDIR"
./svc.sh install botforge
./svc.sh start
echo "runner for env '$ENV_NAME' installed — must show Idle with labels self-hosted,botforge,env-$ENV_NAME"
__BOTFORGE_EOF__
chmod 0755 "/opt/botforge/bin/install-runner.sh"

install -m 0755 -d "$(dirname "/opt/botforge/bin/add-env.sh")"
cat > "/opt/botforge/bin/add-env.sh" <<'__BOTFORGE_EOF__'
#!/usr/bin/env bash
# Add one environment to a provisioned VPS: per-env dirs + runner
# (labels botforge,env-<env>) + systemd service. Same command at
# first boot and later — one command per environment.
# Run as root:  add-env.sh <env> --token <REGISTRATION_TOKEN>
set -Eeuo pipefail
ENV_NAME="${1:?usage: add-env.sh <env> --token <REGISTRATION_TOKEN>}"
shift
TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TOKEN" ]] || { echo "ERROR: --token required (Runners page, valid 1h)" >&2; exit 1; }
[[ "$ENV_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid env name '$ENV_NAME'" >&2; exit 1; }
[[ ! -d "/opt/botforge/runners/$ENV_NAME" ]] || { echo "ERROR: env '$ENV_NAME' already has a runner dir" >&2; exit 1; }
mkdir -p "/opt/botforge/backups/$ENV_NAME" "/opt/botforge/envs/$ENV_NAME/mongo" "/opt/botforge/envs/$ENV_NAME/redis"
chown -R botforge:botforge "/opt/botforge/backups/$ENV_NAME" "/opt/botforge/envs/$ENV_NAME"
/opt/botforge/bin/install-runner.sh "$ENV_NAME" --token "$TOKEN"
__BOTFORGE_EOF__
chmod 0755 "/opt/botforge/bin/add-env.sh"

install -m 0644 -d "$(dirname "/etc/profile.d/botforge.sh")"
cat > "/etc/profile.d/botforge.sh" <<'__BOTFORGE_EOF__'
# BotForge compose helpers (installed by cloud-init — docs/VPS-SETUP.md).
_kwork() {  # print the env's compose dir: the runner's _work checkout
  local env="$1" d
  for d in /opt/botforge/runners/"$env"/_work/*/*/envs/"$env"; do
    [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
  done
  echo "no _work checkout for env '$env' yet (the runner never ran a job — trigger a deploy first)" >&2
  return 1
}
kc() {  # kc <env> <compose args...> — compose in the right dir, with the right vars
  local env="${1:?usage: kc <env> <compose args...>}"; shift
  local dir; dir="$(_kwork "$env")" || return 1
  cd "$dir" || return 1
  export BOTFORGE_IMAGE="$(grep -E '^image:' state/botforge-bot.yml 2>/dev/null | head -1 | cut -d' ' -f2-)"
  export DISCORD_TOKEN="${DISCORD_TOKEN:-placeholder}"
  docker compose "$@"
}
kcl() {  # kcl <env> [service...] — docker compose logs -f (placeholders are fine)
  local env="${1:?usage: kcl <env> [service...]}"; shift
  kc "$env" logs -f "$@"
}
__BOTFORGE_EOF__
chmod 0644 "/etc/profile.d/botforge.sh"

bash /opt/botforge/bin/bootstrap.sh
