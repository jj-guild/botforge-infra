#!/usr/bin/env bash
# BotForge hosting bootstrap — FLAT version of the #cloud-config block in docs/HOSTING-SETUP.md.
# Run as root over SSH:  curl -fsSL <raw-url-of-this-file> | sudo bash
# Generated from docs/HOSTING-SETUP.md — keep in sync.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl jq ufw libicu-dev

install -m 0755 -d "$(dirname "/opt/botforge/bin/bootstrap.sh")"
cat > "/opt/botforge/bin/bootstrap.sh" <<'EOF__opt_botforge_bin_bootstrap.sh'
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
mkdir -p /opt/botforge/bin /opt/botforge/backup /opt/botforge/data /opt/botforge/runners
[[ -f /opt/botforge/envs.json ]] || echo '{}' > /opt/botforge/envs.json
chown -R botforge:botforge /opt/botforge

# load kc/kcl/ll for every interactive user — login shells via
# /etc/profile.d, non-login shells via ~/.bashrc
chmod 755 /etc/profile.d
for h in /root /home/*; do
  [[ -f "$h/.bashrc" ]] || continue
  grep -q 'profile.d/botforge.sh' "$h/.bashrc" || printf '\n# BotForge helpers (kc/kcl/ll)\n[ -f /etc/profile.d/botforge.sh ] && . /etc/profile.d/botforge.sh\n' >> "$h/.bashrc"
done

# --- pinned runner binary, downloaded ONCE, shared by every env ---
RUNNER_VERSION="2.338.2"  # <- version shown on the Runners page
curl -fsSLo "/opt/botforge/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
chown -R botforge:botforge /opt/botforge
EOF__opt_botforge_bin_bootstrap.sh
chmod 0755 "/opt/botforge/bin/bootstrap.sh"

install -m 0755 -d "$(dirname "/opt/botforge/bin/install-runner.sh")"
cat > "/opt/botforge/bin/install-runner.sh" <<'EOF__opt_botforge_bin_install-runner.sh'
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

TARBALL="$(ls /opt/botforge/actions-runner-linux-x64-*.tar.gz 2>/dev/null | head -1)"
if [[ -z "$TARBALL" ]]; then
  RUNNER_VERSION="2.338.2"  # <- version shown on the Runners page
  TARBALL="/opt/botforge/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  curl -fsSLo "$TARBALL" "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
fi

mkdir -p "$RDIR"
chown -R botforge:botforge "$RDIR"
sudo -iu botforge bash -c "cd '$RDIR' && tar xzf '$TARBALL' && ./config.sh --url '$URL' --token '$TOKEN' --labels 'botforge,env-$ENV_NAME'"
cd "$RDIR"
./svc.sh install botforge
./svc.sh start
echo "runner for env '$ENV_NAME' installed — must show Idle with labels self-hosted,botforge,env-$ENV_NAME"
EOF__opt_botforge_bin_install-runner.sh
chmod 0755 "/opt/botforge/bin/install-runner.sh"

install -m 0755 -d "$(dirname "/opt/botforge/bin/add-env.sh")"
cat > "/opt/botforge/bin/add-env.sh" <<'EOF__opt_botforge_bin_add-env.sh'
#!/usr/bin/env bash
# Manage one environment on a provisioned hosting. Reads/writes
# /opt/botforge/envs.json (object: env -> metadata) to decide what to do.
#   add-env.sh <env> --token <REGISTRATION_TOKEN>   create, or re-register if it already exists
#   add-env.sh <env> --remove                       remove runner + dirs + envs.json entry
# Run as root.
set -Eeuo pipefail
ENV_NAME="${1:?usage: add-env.sh <env> --token <TOKEN> | add-env.sh <env> --remove}"
shift
MODE="add"
TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:?}"; shift 2 ;;
    --remove) MODE="remove"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ "$ENV_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid env name '$ENV_NAME'" >&2; exit 1; }
ENVS_JSON=/opt/botforge/envs.json
[[ -f "$ENVS_JSON" ]] || echo '{}' > "$ENVS_JSON"
RDIR="/opt/botforge/runners/$ENV_NAME"

if [[ "$MODE" == "remove" ]]; then
  if ! jq -e --arg e "$ENV_NAME" 'has($e)' "$ENVS_JSON" >/dev/null; then
    echo "env '$ENV_NAME' not in $ENVS_JSON — nothing to do"
    exit 0
  fi
  if [[ -d "$RDIR" ]]; then (cd "$RDIR" && ./svc.sh stop && ./svc.sh uninstall) 2>/dev/null || true; fi
  rm -rf "$RDIR" "/opt/botforge/backup/$ENV_NAME" "/opt/botforge/data/$ENV_NAME"
  jq --arg e "$ENV_NAME" 'del(.[$e])' "$ENVS_JSON" > "$ENVS_JSON.tmp" && mv "$ENVS_JSON.tmp" "$ENVS_JSON"
  echo "env '$ENV_NAME' removed (runner, backup/, data/ dirs, envs.json entry)"
  exit 0
fi

[[ -n "$TOKEN" ]] || { echo "ERROR: --token required (Runners page, valid 1h)" >&2; exit 1; }
if jq -e --arg e "$ENV_NAME" 'has($e)' "$ENVS_JSON" >/dev/null && [[ -d "$RDIR" ]]; then
  echo "env '$ENV_NAME' already exists — re-registering runner with the new token (no reinstall)"
  (cd "$RDIR" && sudo -u botforge ./config.sh --url https://github.com/jj-guild/botforge-infra --token "$TOKEN" --labels "botforge,env-$ENV_NAME" --replace)
  (cd "$RDIR" && ./svc.sh start) || true
else
  echo "env '$ENV_NAME' not present — creating it"
  mkdir -p "/opt/botforge/backup/$ENV_NAME" "/opt/botforge/data/$ENV_NAME/mongo" "/opt/botforge/data/$ENV_NAME/redis"
  chown -R botforge:botforge "/opt/botforge/backup/$ENV_NAME" "/opt/botforge/data/$ENV_NAME"
  /opt/botforge/bin/install-runner.sh "$ENV_NAME" --token "$TOKEN"
fi
jq --arg e "$ENV_NAME" --arg labels "botforge,env-$ENV_NAME" --arg dir "$RDIR" '.[$e] = {labels: $labels, runner_dir: $dir}' "$ENVS_JSON" > "$ENVS_JSON.tmp" && mv "$ENVS_JSON.tmp" "$ENVS_JSON"
echo "env '$ENV_NAME' recorded in $ENVS_JSON"
EOF__opt_botforge_bin_add-env.sh
chmod 0755 "/opt/botforge/bin/add-env.sh"

install -m 0755 -d "$(dirname "/etc/profile.d/botforge.sh")"
cat > "/etc/profile.d/botforge.sh" <<'EOF__etc_profile.d_botforge.sh'
# BotForge compose helpers (installed by cloud-init — docs/HOSTING-SETUP.md).
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
  jq -e --arg e "$env" 'has($e)' /opt/botforge/envs.json >/dev/null || { echo "unknown env '$env' — see /opt/botforge/envs.json" >&2; return 1; }
  local dir; dir="$(_kwork "$env")" || return 1
  cd "$dir" || return 1
  export BOTFORGE_IMAGE="$(grep -E '^image:' state/botforge-bot.yml 2>/dev/null | head -1 | cut -d' ' -f2-)"
  export DISCORD_TOKEN="${DISCORD_TOKEN:-placeholder}"
  sudo docker compose "$@"
}
kcl() {  # kcl <env> [service...] — docker compose logs -f (placeholders are fine)
  local env="${1:?usage: kcl <env> [service...]}"; shift
  kc "$env" logs -f "$@"
}

alias ll='ls -al'
EOF__etc_profile.d_botforge.sh
chmod 0644 "/etc/profile.d/botforge.sh"

bash /opt/botforge/bin/bootstrap.sh
