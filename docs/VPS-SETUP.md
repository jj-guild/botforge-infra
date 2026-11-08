# VPS setup guide — cloud-init bootstrap

This guide turns a fresh VPS into a fully automated GitOps deployment
target **at first boot**, via one cloud-init user-data block. It is
written as commands to copy-paste: it assumes you already know ssh,
GitHub Actions runners and Docker — no tutorials, one verification
command per step.

Tracked by merlin-pinpin-org/kingdoms-services#331 (lot 2).

## What you are building

- One VPS hosting **one or more environments** (a full stack per
  environment: bot + MongoDB + Redis). Each environment gets exactly
  **one self-hosted runner labeled `env-<name>`** under
  `/opt/kingdoms/runners/<env>/` — the deploy workflows route jobs by
  that label.
- Persistent data outside the runner's work directory:
  `/opt/kingdoms/backups/<env>/` (deployment backups) and
  `/opt/kingdoms/envs/<env>/{mongo,redis}` (bind-mount targets — they
  survive a `docker compose down --volumes` reset).
- Secrets (the Discord bot token) are **never stored on the VPS**: they
  live in GitHub *environment secrets* and the runner injects them at
  deploy time.

## 0. Prerequisites

- A VPS with **Ubuntu Server 26.04 LTS**, at least **2 GB RAM / 20 GB
  disk**, and your SSH key (any provider: OVH, Scaleway, Hetzner,
  DigitalOcean…).
- On GitHub (`merlin-pinpin-org/kingdoms-infra`), per environment you
  will host:
  - a **GitHub environment** named `<env>` — created in step 3 with its
    secrets;
  - a **runner registration token**: Settings → Actions → Runners → New
    self-hosted runner → Linux/x64 (the token is valid **1 hour**).

## 1. Provision the VPS with cloud-init

Create the instance and paste the following block in the provider's
**user data / cloud-init** field, then boot. Replace `2.337.0` with the
runner version currently shown on the Runners page.

```yaml
#cloud-config
# Kingdoms VPS bootstrap — libs, users, multi-env filesystem, pinned
# runner binary, helper scripts and shell aliases. Runner registration
# is deliberately NOT done here (registration tokens live 1h): it is
# step 2, with the same add-env.sh command used later for more envs.
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - jq
  - ufw
write_files:
  - path: /opt/kingdoms/bin/bootstrap.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      export DEBIAN_FRONTEND=noninteractive

      # --- Docker Engine + Compose plugin (official repo) ---
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker

      # --- service user: no password, no sudo, in the docker group ---
      id kingdoms >/dev/null 2>&1 || adduser --disabled-password --gecos "" kingdoms
      usermod -aG docker kingdoms

      # --- firewall: SSH only (the stack exposes no public port) ---
      ufw allow OpenSSH
      ufw --force enable

      # --- multi-env filesystem layout ---
      mkdir -p /opt/kingdoms/bin /opt/kingdoms/backups /opt/kingdoms/runners /opt/kingdoms/envs
      chown -R kingdoms:kingdoms /opt/kingdoms

      # --- pinned runner binary, downloaded ONCE, shared by every env ---
      RUNNER_VERSION="2.337.0"  # <- version shown on the Runners page
      echo "$RUNNER_VERSION" > /opt/kingdoms/runners/.runner-version
      curl -fsSLo "/opt/kingdoms/runners/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
      chown -R kingdoms:kingdoms /opt/kingdoms/runners
  - path: /opt/kingdoms/bin/install-runner.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Register one self-hosted runner for <env> and install it as a
      # systemd service. Run as root:
      #   install-runner.sh <env> --token <REGISTRATION_TOKEN> [--url https://github.com/ORG/kingdoms-infra]
      set -Eeuo pipefail
      ENV_NAME="${1:?usage: install-runner.sh <env> --token <REGISTRATION_TOKEN> [--url <repo-url>]}"
      shift
      TOKEN="" URL="https://github.com/merlin-pinpin-org/kingdoms-infra"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --token) TOKEN="${2:?}"; shift 2 ;;
          --url)   URL="${2:?}";   shift 2 ;;
          *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
      done
      [[ -n "$TOKEN" ]] || { echo "ERROR: --token required (Runners page, valid 1h)" >&2; exit 1; }
      [[ "$ENV_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid env name '$ENV_NAME'" >&2; exit 1; }
      RDIR="/opt/kingdoms/runners/$ENV_NAME"
      [[ ! -d "$RDIR" ]] || { echo "ERROR: $RDIR already exists (env '$ENV_NAME' already installed)" >&2; exit 1; }

      RUNNER_VERSION="$(cat /opt/kingdoms/runners/.runner-version)"
      TARBALL="/opt/kingdoms/runners/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
      [[ -f "$TARBALL" ]] || curl -fsSLo "$TARBALL" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

      mkdir -p "$RDIR"
      chown -R kingdoms:kingdoms "$RDIR"
      sudo -iu kingdoms bash -c "cd '$RDIR' && tar xzf '$TARBALL' && ./config.sh --url '$URL' --token '$TOKEN' --labels 'kingdoms,env-$ENV_NAME'"
      cd "$RDIR"
      ./svc.sh install kingdoms
      ./svc.sh start
      echo "runner for env '$ENV_NAME' installed — must show Idle with labels self-hosted,kingdoms,env-$ENV_NAME"
  - path: /opt/kingdoms/bin/add-env.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Add one environment to a provisioned VPS: per-env dirs + runner
      # (labels kingdoms,env-<env>) + systemd service. Same command at
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
      [[ ! -d "/opt/kingdoms/runners/$ENV_NAME" ]] || { echo "ERROR: env '$ENV_NAME' already has a runner dir" >&2; exit 1; }
      mkdir -p "/opt/kingdoms/backups/$ENV_NAME" "/opt/kingdoms/envs/$ENV_NAME/mongo" "/opt/kingdoms/envs/$ENV_NAME/redis"
      chown -R kingdoms:kingdoms "/opt/kingdoms/backups/$ENV_NAME" "/opt/kingdoms/envs/$ENV_NAME"
      /opt/kingdoms/bin/install-runner.sh "$ENV_NAME" --token "$TOKEN"
  - path: /etc/profile.d/kingdoms.sh
    permissions: "0644"
    content: |
      # Kingdoms compose helpers (installed by cloud-init — docs/VPS-SETUP.md).
      _kwork() {  # print the env's compose dir: the runner's _work checkout
        local env="$1" d
        for d in /opt/kingdoms/runners/"$env"/_work/*/*/envs/"$env"; do
          [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
        done
        echo "no _work checkout for env '$env' yet (the runner never ran a job — trigger a deploy first)" >&2
        return 1
      }
      kc() {  # kc <env> <compose args...> — compose in the right dir, with the right vars
        local env="${1:?usage: kc <env> <compose args...>}"; shift
        local dir; dir="$(_kwork "$env")" || return 1
        cd "$dir" || return 1
        export KINGDOMS_BOT_IMAGE="$(grep -E '^image:' state/kingdoms-bot.yml 2>/dev/null | head -1 | cut -d' ' -f2-)"
        export DISCORD_TOKEN="${DISCORD_TOKEN:-placeholder}"
        docker compose "$@"
      }
      kcl() {  # kcl <env> [service...] — docker compose logs -f (placeholders are fine)
        local env="${1:?usage: kcl <env> [service...]}"; shift
        kc "$env" logs -f "$@"
      }
runcmd:
  - bash /opt/kingdoms/bin/bootstrap.sh
```

What the boot installs: the base libraries, Docker Engine + Compose,
`ufw` (SSH only), the `kingdoms` service user (no password, no sudo,
docker group), the `/opt/kingdoms/{bin,backups,runners,envs}` layout,
the pinned runner tarball (shared by all environments), the helper
scripts `/opt/kingdoms/bin/{bootstrap,install-runner,add-env}.sh`, and
the `kc` / `kcl` shell aliases via `/etc/profile.d/kingdoms.sh`.

**Verify** (first ssh login):

```bash
ssh <host>
sudo cloud-init status --wait        # ends with "done"
docker run hello-world
docker compose version
ls /opt/kingdoms/bin                 # bootstrap.sh install-runner.sh add-env.sh
sudo -u kingdoms docker ps           # docker group membership OK
```

The aliases load on the **next** login (profile.d): `exit`, reconnect,
then `type kc kcl`.

## 2. Register the runner(s) — one command per environment

```bash
# token from Settings → Actions → Runners → New self-hosted runner (Linux/x64)
sudo /opt/kingdoms/bin/add-env.sh test --token <TOKEN>

# more environments on the SAME VPS — same command, nothing else to redo:
sudo /opt/kingdoms/bin/add-env.sh dev-merlin  --token <TOKEN>
sudo /opt/kingdoms/bin/add-env.sh dev-drasah --token <TOKEN>
```

Each call creates `/opt/kingdoms/{backups,envs}/<env>/`, registers the
runner with labels `kingdoms,env-<env>` in
`/opt/kingdoms/runners/<env>/`, and installs + starts its systemd
service.

**Verify** — every env runner must be online/Idle with the right labels:

```bash
gh api /repos/merlin-pinpin-org/kingdoms-infra/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
# or the Runners page: each env runner Idle (green),
# labels self-hosted, kingdoms, env-<env>
cd /opt/kingdoms/runners/<env> && sudo ./svc.sh status
```

## 3. GitHub environments and secrets (per environment)

On `merlin-pinpin-org/kingdoms-infra`: **Settings → Environments →
`<env>`** — add the environment **secret** `DISCORD_TOKEN` (that
environment's bot token, from the Discord developer portal) and the
environment **variable** `BOT_ADMINS` (comma-separated Discord user IDs
of that bot's operators). Repeat per environment (`test`, `dev-merlin`,
…). Nothing secret is ever written to the VPS — the runner picks the
secrets up at deploy time.

## 4. First deployment

1. Actions tab → **Deploy environment** workflow → **Run workflow**,
   environment `test`.
2. The job checks out the `deploy/<env>` state branch into the
   runner's `_work` directory and runs `scripts/deploy.sh` (backup →
   apply → health gate → rollback on failure; the backup step is
   skipped on the very first deployment).

**Verify:**

```bash
docker ps --filter name=kingdoms
# kingdoms-bot, kingdoms-mongo, kingdoms-redis must all show (healthy)
```

## 5. Adding an environment later

Environments are data (see [ENVIRONMENTS.md](ENVIRONMENTS.md)): one
`envs/<name>/` manifest + state, one `deploy/<name>` state branch, one
GitHub environment, one runner label. On a VPS provisioned with this
guide, the VPS part is a single command:

```bash
sudo /opt/kingdoms/bin/add-env.sh <env> --token <TOKEN>
```

…then create the GitHub environment with its secrets (step 3) and the
repo data (manifest + `deploy/<env>` branch) per the
[ENVIRONMENTS.md](ENVIRONMENTS.md) checklist. Existing environments on
the same VPS are untouched — same scripts, same paths, shared tarball.

## 6. Daily operation — the aliases

On any fresh ssh login, `/etc/profile.d/kingdoms.sh` provides:

| Command | What it does |
| ------- | ------------ |
| `kc <env> ps` | `docker compose ps` **in the env's `_work` directory**, with the env vars set |
| `kc <env> up -d` / `down` / `restart` / `config --services` … | any compose args, same wrapping |
| `kcl <env> [service...]` | `docker compose logs -f [service...]` |
| `sudo /opt/kingdoms/bin/add-env.sh <env> --token <T>` | add an environment |
| `cd /opt/kingdoms/runners/<env> && sudo ./svc.sh status` | runner service status |
| `make doctor` (from a clone) | deploy-chain diagnosis, FLAG lines |

**Env-var note (why no manual workaround is needed).** `kc` exports
`KINGDOMS_BOT_IMAGE` from the pinned state file
(`state/kingdoms-bot.yml` inside the env's `_work` checkout) and
`DISCORD_TOKEN` from your shell if set, otherwise `placeholder`.
Compose fails closed on **unset** substitution variables; for
`ps` / `logs` / `stop` / `start` the values are irrelevant, so the
placeholder is enough and **no secret is ever needed on the VPS**. Real
secrets are injected only by the runner at deploy time (GitHub
environment secrets). Never type a real `DISCORD_TOKEN` in an
interactive shell on the VPS.

## 7. The rename — merlin-pinpin-org/kingdoms-services#241

The org/repo rename changes: the runner registration `--url`, the
`gh api /repos/<org>/…` paths, the `ghcr.io/<org>/…` image prefix and
the git remotes. Runner labels (`kingdoms`, `env-<env>`) and the
`deploy/<env>` state branch names are unchanged.

Post-rename checklist:

1. Reinstall the VPS with this guide (the baked-in default `--url` is
   updated in the same change).
2. Re-register the runners (step 2) against the new repo URL.
3. Trigger a first deployment per env (step 4) and verify the image
   pulls from the new `ghcr.io/<org>/…` prefix.
4. Re-run the step-4 health verification (`docker ps --filter
   name=kingdoms`).

## 8. Troubleshooting

- **cloud-init failed or is slow**: `sudo cloud-init status --long`,
  `sudo tail -n 50 /var/log/cloud-init-output.log`.
- **`kc` says "no _work checkout"**: the runner never ran a job —
  trigger a deploy first (step 4); the checkout appears under
  `/opt/kingdoms/runners/<env>/_work/`.
- **Deploy stays pending, nothing notifies**: run `make doctor` (or
  `make diagnose-deploy-<env>`) from a clone *before* checking the
  runner — a stale run can hold the `deploy-<env>` concurrency group
  while the runner is healthy and idle.
- **Runner offline**: `cd /opt/kingdoms/runners/<env> && sudo ./svc.sh
  status`, restart with `sudo ./svc.sh start`.
- **Runner never goes Idle / service fails to start**: wrong file owner
  — `config.sh` must run as `kingdoms`. Fix with `sudo chown -R
  kingdoms:kingdoms /opt/kingdoms/runners/<env>`, then `sudo ./svc.sh
  start`; check `sudo journalctl -u actions.runner.* -e`.
- **`deploy.sh` says `DISCORD_TOKEN is not set`**: the GitHub
  environment of that env has no `DISCORD_TOKEN` secret (step 3).
- **Health gate fails and rolls back**: `kcl <env> kingdoms-bot` — the
  usual causes are an invalid token or an image-pull rate limit.
- **Permission denied from Docker**: `usermod -aG docker kingdoms` ran
  but your shell predates it — switch again with `sudo -iu kingdoms`.
- **Known pitfalls from past sessions**: Discord throttling ~2 h after
  intensive provisioning; `systemd-resolved` DNS quirks; the
  `/opt/kingdoms/envs/<env>` bind mounts survive a VPS reset **by
  design** (that is the data).

## Out of scope — lot 4

The laptop CLI (`vpsctl`: bootstrap / diagnose / start / stop / restart
/ status / logs against the VPS from your own machine, configured only
through a `~/.ssh/config` alias) is **not** part of this guide — it is
tracked in merlin-pinpin-org/kingdoms-services#349.

## See also

- [RUNNER.md](RUNNER.md) — manual runner install/uninstall cheat-sheet
  (the raw commands behind `add-env.sh`)
- [ENVIRONMENTS.md](ENVIRONMENTS.md) — environment matrix + add-an-env
  checklist
- [DEPLOYMENT.md](DEPLOYMENT.md) — the deploy chain
- merlin-pinpin-org/kingdoms-infra#5 — monitoring (resource usage, alerts)
