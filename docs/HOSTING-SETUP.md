# Hosting setup guide — cloud-init bootstrap

> **One file, two speeds:** the **Fast path** below is commands-only for
> people who know what they're doing; expandable `<details>` blocks and
> the §0–§8 sections + glossary are for first-timers.

This guide turns a fresh hosting into a fully automated GitOps deployment
target **at first boot**, via one cloud-init user-data block. Every step
has copy-paste commands and a verification command with the output you
should expect.

**First time doing this?** Skip to the **Fast path** below and expand
the `<details>` blocks as you go — they are the plain-words version
(where to click, what to copy, what each thing is). The §0–§8 sections
are the full reference; a glossary is at the end of this page.

Tracked by jj-guild/botforge-services#331 (lot 2).

## What you are building

- One hosting server (a VM) hosting **one or more environments** (a full stack per
  environment: bot + MongoDB + Redis). Each environment gets exactly
  **one self-hosted runner labeled `env-<name>`** under
  `/opt/botforge/runners/<env>/` — the deploy workflows route jobs by
  that label.
- Persistent data outside the runner's work directory:
  `/opt/botforge/backup/<env>/` (deployment backups) and
  `/opt/botforge/data/<env>/{mongo,redis}` (bind-mount targets — they
  survive a `docker compose down --volumes` reset).
- The runner tarball is downloaded **once**, at the root of
  `/opt/botforge/` (`actions-runner-linux-x64-<version>.tar.gz`), and only
  extracted per env into `runners/<env>/` — no 218 MB download per env.
- `/opt/botforge/envs.json` lists the envs installed on this machine;
  `add-env.sh` maintains it and the `kc`/`kcl` aliases check it.
- Secrets (the Discord bot token) are **never stored on the hosting**: they
  live in GitHub *environment secrets* and the runner injects them at
  deploy time.

## Fast path — commands only (experts)

Skim this, run it, done. Every step shows the expected output in a
comment; `<details>` blocks under each step are the plain-words
explanations for first-timers. Full details follow in the sections below
(§0–§8), glossary at the end.


#### 0. Prereqs

```bash
# On your computer, if you have no SSH key yet:
ssh-keygen -t ed25519 -C "you@example.com"     # then: cat ~/.ssh/id_ed25519.pub
```

- Cloud provider account (OVH Public Cloud / Hetzner / Scaleway / DigitalOcean…)
- GitHub access to `jj-guild/botforge-infra` (Settings → Actions → Runners, Settings → Environments)
- Per env: the env's Discord bot token (Discord developer portal → Bot → Reset Token) + operator Discord user IDs

<details><summary>First time? what each of these is</summary>

- **Instance/VM** = a small virtual server in the cloud, with an IP you `ssh` into.
- **cloud-init / user-data** = a script given to the provider at creation; it runs automatically at first boot (installs Docker, the `botforge` user, firewall, folders).
- **Self-hosted runner** = a program on the server that runs GitHub Actions deploy jobs. One per environment, labeled `botforge,env-<env>`.
- **Environment** (`test`, `dev-merlin`, …) = one isolated stack (bot + MongoDB + Redis) on the server: own runner, own GitHub secrets, own `deploy/<env>` state branch.
- **Secret vs variable**: a secret (`DISCORD_TOKEN`) is encrypted in GitHub and injected only into deploy jobs — never stored/displayed on the server. A variable (`BOT_ADMINS`) is a plain setting.

</details>

#### 1. Create the instance

Provider console → new instance: **Debian 13** (Ubuntu 26.04 LTS ok), **≥ 2 GB RAM / 20 GB disk**, paste your **public** SSH key. Boot.

- If the creation form has a **user data / cloud-init** field → paste the **`#cloud-config` block from this step** there (first line `#cloud-config`; set the runner version to the one shown on the Runners page).
- **No such field (OVH Public Cloud has none)** → skip it; the one-liner in step 2 does the exact same thing over SSH.

If the field exists, paste this block there:

```yaml
#cloud-config
# BotForge hosting bootstrap — libs, users, multi-env filesystem, pinned
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
  - libicu-dev   # the GitHub runner (.NET 6) needs libicu on Debian
write_files:
  - path: /opt/botforge/bin/bootstrap.sh
    permissions: "0755"
    content: |
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
      # adopt runner dirs that predate envs.json (registered by hand):
      for d in /opt/botforge/runners/*/; do
        e="$(basename "$d")"
        [[ "$e" == .* ]] && continue
        if ! jq -e --arg e "$e" 'has($e)' /opt/botforge/envs.json >/dev/null 2>&1; then
          jq --arg e "$e" --arg labels "botforge,env-$e" --arg dir "/opt/botforge/runners/$e" \
            '.[$e] = {labels: $labels, runner_dir: $dir}' /opt/botforge/envs.json > /opt/botforge/envs.json.tmp \
            && mv /opt/botforge/envs.json.tmp /opt/botforge/envs.json
        fi
      done
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
  - path: /opt/botforge/bin/install-runner.sh
    permissions: "0755"
    content: |
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
  - path: /opt/botforge/bin/add-env.sh
    permissions: "0755"
    content: |
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
  - path: /etc/profile.d/botforge.sh
    permissions: "0644"
    content: |
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
        if ! jq -e --arg e "$env" 'has($e)' /opt/botforge/envs.json >/dev/null 2>&1 && [[ ! -d "/opt/botforge/runners/$env" ]]; then
          echo "unknown env '$env' — see /opt/botforge/envs.json" >&2; return 1
        fi
        local dir; dir="$(_kwork "$env")" || return 1
        cd "$dir" || return 1
        export BOTFORGE_IMAGE="$(sudo grep -E '^image:' state/botforge-bot.yml 2>/dev/null | head -1 | cut -d' ' -f2-)"
        [[ -n "$BOTFORGE_IMAGE" ]] || { echo "no pin in state/botforge-bot.yml under $dir — did a deploy run on env '$env' yet?" >&2; return 1; }
        export DISCORD_TOKEN="${DISCORD_TOKEN:-placeholder}"
        sudo docker compose "$@"
      }
      kcl() {  # kcl <env> [service...] — docker compose logs -f (placeholders are fine)
        local env="${1:?usage: kcl <env> [service...]}"; shift
        kc "$env" logs -f "$@"
      }

      alias ll='ls -al'
runcmd:
  - bash /opt/botforge/bin/bootstrap.sh
```


<details><summary>First time? where exactly</summary>

- OVH Public Cloud: project → Compute → Create an instance → OS "Debian 13", flavor ≥ 2 GB, paste the public key under "SSH key". The user-data field is the "Configuration"/advanced section of the creation form.
- The instance gets a public IP — you'll ssh into it in the next step. Login user = image name (usually `debian`).

</details>

#### 2. First SSH login — verify the bootstrap

```bash
ssh debian@<instance-ip>
# No user-data field at creation (e.g. OVH Public Cloud)? This one-liner
# runs the same bootstrap as the cloud-init block:
curl -fsSL https://raw.githubusercontent.com/jj-guild/botforge-infra/main/scripts/vps/bootstrap-flat.sh | sudo bash
# (runner version differs from 2.337.0 -> insert: | sed 's/2\.338\.2/NEW/' before 'sudo bash')
# If you DID paste the cloud-init block: instead check it ran:
#   sudo cloud-init status --wait   # Expected: "status: done"
ls /opt/botforge/bin              # Expected: bootstrap.sh install-runner.sh add-env.sh
docker --version && docker compose version
sudo docker run hello-world      # Expected: "Hello from Docker!" (socket = root/docker group only; as the image user use sudo, e.g. sudo -u botforge docker ps)
id botforge                       # Expected: groups=…(docker)
sudo ufw status verbose           # Expected: Status: active, OpenSSH ALLOW
```

<details><summary>First time? what just happened</summary>

cloud-init ran the block you pasted at creation: it installed the packages, Docker, the `botforge` user (in the `docker` group, no password/sudo), enabled the firewall (SSH only — the stack exposes no public port), created `/opt/botforge/{bin,backup,data,runners} + the runner tarball at the root`, downloaded the pinned runner tarball, and wrote the `kc`/`kcl` aliases (`/etc/profile.d/botforge.sh`, active at the **next** login).

Note: the Docker socket answers only to root and the `docker` group — as the image user (`debian`…) prefix docker commands with `sudo`, or switch user: `sudo -iu botforge`.

</details>

**What the boot installs** (the one-liner runs the same content): the base libraries, Docker Engine + Compose,
`ufw` (SSH only), the `botforge` service user (no password, no sudo,
docker group), the `/opt/botforge/{bin,backup,data,runners} + the runner tarball at the root` layout,
the pinned runner tarball (shared by all environments), the helper
scripts `/opt/botforge/bin/{bootstrap,install-runner,add-env}.sh`, and
the `kc` / `kcl` shell aliases via `/etc/profile.d/botforge.sh`.

#### 3. Register one runner per env

**Get a token — default: the web UI** (what 80% of people do):
open <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>
(GitHub → repo `jj-guild/botforge-infra` → Settings → Actions → Runners →
New self-hosted runner, Linux/x64), copy the token. It is shown **once**
and is valid **1 h**.

**Only if you script it** (20%): run this on **your own computer** (needs
`gh` installed + `gh auth login`), then paste the token value on the
server:

```bash
# on YOUR machine:
REG='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$REG" --jq '.token'
```

**Layout under `/opt/botforge/`:**

```
/opt/botforge/
├── bin/                              # our scripts (install, add-env, logs…)
├── backup/                           # dumps, one subdir per env: backup/<env>/
├── data/                             # docker volumes, per env: data/<env>/{mongo,redis}
├── runners/                          # one installed runner per env: runners/<env>/
├── actions-runner-linux-x64-2.338.2.tar.gz   # the installer, downloaded ONCE at the root
└── envs.json                         # registry of envs on this machine: env → {labels, runner_dir}
```

(libicu is installed by the bootstrap's `libicu-dev` package — if you
bootstrapped before that fix, run once as root: `sudo apt-get install -y libicu-dev`)

```bash
# one-time, shared: download the runner installer to the ROOT of /opt/botforge
# (runner version = the one shown on the Runners page; 2.338.2 below)
sudo -u botforge bash -c 'cd /opt/botforge && \
  curl -fsSLo actions-runner-linux-x64-2.338.2.tar.gz -L https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz && \
  echo "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40  actions-runner-linux-x64-2.338.2.tar.gz" | shasum -a 256 -c'

# per environment — fresh token each time (valid 1 h):
# which env this runner serves:
ENV=test
# the token from the UI (or from the gh command above):
TOKEN=<TOKEN>

# per-env dirs (runner dir + backup dir + data bind mounts):
sudo install -d -o botforge -g botforge \
  "/opt/botforge/runners/$ENV" "/opt/botforge/backup/$ENV" \
  "/opt/botforge/data/$ENV/mongo" "/opt/botforge/data/$ENV/redis"

# extract the SHARED installer (root-level tarball) into this env's runner dir, configure as botforge:
sudo -u botforge bash -c "cd /opt/botforge/runners/$ENV && \
  tar xzf /opt/botforge/actions-runner-linux-x64-2.338.2.tar.gz && \
  ./config.sh --url https://github.com/jj-guild/botforge-infra --token $TOKEN --labels botforge,env-$ENV"

# as root: install + start the systemd service (runs as botforge):
cd "/opt/botforge/runners/$ENV" && sudo ./svc.sh install botforge && sudo ./svc.sh start
sudo ./svc.sh status
# Expected: active (running)
```

**Verify on GitHub:** Runners page → the runner is **Idle** (green), labels
`self-hosted, botforge, env-<env>`. Repeat per env (`ENV=dev-merlin`…) with a
fresh token each time — token page: <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>. (One-command wrapper, driven by `envs.json`: Token page each time: <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>
`sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>` creates the env
if absent, **re-registers** it if it already exists (nothing reinstalled);
`sudo /opt/botforge/bin/add-env.sh <env> --remove` deletes it — runner
service, dirs, `envs.json` entry.)

<details><summary>First time? why a token, why labels, why that layout</summary>

- The **token** is a one-time, 1-hour password that attaches a runner to
  the repo — copy it immediately, use it within the hour.
- **Labels** are how deploy workflows pick the right runner:
  `self-hosted, botforge, env-<env>`.
- The runner runs **as `botforge`** in `/opt/botforge/runners/<env>` so
  deploy jobs can write `_work/` there; the **installer tarball is
  downloaded once** at the root of `/opt/botforge/` and only extracted
  per env. `svc.sh` makes the service survive reboots. `envs.json` records
  which envs live on this machine and the `kc`/`kcl` aliases read it.

</details>


#### 4. GitHub environment secrets (per env)

Repo `jj-guild/botforge-infra` → **Settings → Environments → `<env>`**:

- **Secret** `DISCORD_TOKEN` = that env's bot token
- **Variable** `BOT_ADMINS` = comma-separated operator Discord user IDs

Nothing secret is ever stored on the server.

#### 5. First deployment

Repo → **Actions** → **Deploy environment** → **Run workflow** → environment `test`. Expected: green in a few minutes. On the server:

```bash
docker ps --filter name=botforge   # Expected: botforge-bot, botforge-mongo, botforge-redis — Up/healthy
```

And in Discord: the test bot answers `/status`.

#### 6. More envs + order after a reinstall

Add an env later on the same server — get a **fresh token at** <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new> (shown once, 1 h), then:
```bash
sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>
```
Nothing else to redo. Remove an env: on the server
`sudo /opt/botforge/bin/add-env.sh <env> --remove` (stops the runner service, deletes `runners/<env>`, `backup/<env>`, `data/<env>`, and its `envs.json` entry); on GitHub, Runners page → that runner → **Remove** (use the removal token shown there with `./config.sh remove --token <REMOVAL_TOKEN>` inside `/opt/botforge/runners/<env>` first if the service is still installed).

Validate each env before the next (`scripts/diagnose_env.sh` + `/status` in Discord). Order: **merlin → test → prod** (prod only at a release promotion).

#### 7. Daily ops

Run `kc`/`kcl` as your **SSH user** (`debian`, or root) — never as `botforge` (the `botforge` user has no sudo by design; `kc` calls `sudo` internally for the pin read and docker):

```bash
kc <env> ps             # what's running in that env
kcl <env> botforge-bot  # follow the bot's logs
```

(`kc` sets `BOTFORGE_IMAGE` from the pinned `envs/<env>/state/botforge-bot.yml` automatically.)

#### If something goes wrong

| Symptom | Fix |
| --- | --- |
| Token rejected/expired | fetch a new one (1 h validity), rerun `./config.sh …` |
| `cloud-init status` not `done` | wait; `sudo tail -n 50 /var/log/cloud-init-output.log` |
| Runner Offline on the Runners page | on the server: `cd /opt/botforge/runners/<env> && sudo ./svc.sh status` |
| Deploy workflow stays pending | label mismatch — check `self-hosted, botforge, env-<env>` on the runner |

More: Troubleshooting at the end of this page.

---

## Daily operation — the aliases

On any fresh ssh login, `/etc/profile.d/botforge.sh` provides:

| Command | What it does |
| ------- | ------------ |
| `kc <env> ps` | `docker compose ps` **in the env's `_work` directory**, with the env vars set |
| `kc <env> up -d` / `down` / `restart` / `config --services` … | any compose args, same wrapping |
| `kcl <env> [service...]` | `docker compose logs -f [service...]` |
| `sudo /opt/botforge/bin/add-env.sh <env> --token <T>` | add an environment |
| `cd /opt/botforge/runners/<env> && sudo ./svc.sh status` | runner service status |
| `make doctor` (from a clone) | deploy-chain diagnosis, FLAG lines |

**Env-var note (why no manual workaround is needed).** `kc` exports
`BOTFORGE_IMAGE` from the pinned state file
(`state/botforge-bot.yml` inside the env's `_work` checkout) and
`DISCORD_TOKEN` from your shell if set, otherwise `placeholder`.
Compose fails closed on **unset** substitution variables; for
`ps` / `logs` / `stop` / `start` the values are irrelevant, so the
placeholder is enough and **no secret is ever needed on the hosting**. Real
secrets are injected only by the runner at deploy time (GitHub
environment secrets). Never type a real `DISCORD_TOKEN` in an
interactive shell on the hosting.

## Naming reference (current state)

- Org: `jj-guild`. Repos: `botforge` (docs), `botforge-services` (code),
  `botforge-infra` (this repo), `visual-generator`.
- Images: `ghcr.io/jj-guild/botforge-services:<tag>`.
- Git remotes and `gh api /repos/jj-guild/…` paths use the names above.
- Runner registration `--url`: `https://github.com/jj-guild/botforge-infra`.
- Runner labels: `botforge`, `env-<env>`. State branches: `deploy/<env>`.
- Hosting user/paths: `botforge`, `/opt/botforge/…`. Image env var:
  `BOTFORGE_IMAGE` (read from `envs/<env>/state/botforge-bot.yml`).


## Troubleshooting

- **`kc`/`kcl`: command not found, or `source /etc/profile.d/botforge.sh`
  says Permission denied** → `/etc/profile.d` must be traversable:
  `sudo chmod 755 /etc/profile.d`. The aliases load at login (profile.d)
  and in every interactive shell (the bootstrap appends a hook to each
  `~/.bashrc`). Reconnect, or in the current session: `source ~/.bashrc`.
  `ll` = `ls -al` is defined in the same file.

- **Re-running the bootstrap is safe (idempotent)**: user creation is
  guarded, `mkdir -p`, `apt install`, `ufw allow` and the download are all
  re-runnable. To start completely fresh instead (e.g. after a layout
  change, leaving both `backup/` and `data/` around): no need to reset the
  instance —
  ```bash
  # stop + uninstall the runner services, then wipe the tree and re-run the one-liner:
  for e in test merlin; do (cd "/opt/botforge/runners/$e" 2>/dev/null && sudo ./svc.sh stop && sudo ./svc.sh uninstall) || true; done
  sudo rm -rf /opt/botforge
  curl -fsSL https://raw.githubusercontent.com/jj-guild/botforge-infra/vibe/docs-hosting-01fb7e/scripts/vps/bootstrap-flat.sh | sudo bash
  ```
  then on the GitHub Runners page remove the stale (Offline) runners, and
  re-register each env with a fresh token:
  `sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>` (this also
  records the env in `envs.json`). Finally re-run the deploy (Actions →
  Deploy environment on `deploy/<env>`).

- **cloud-init failed or is slow**: `sudo cloud-init status --long`,
  `sudo tail -n 50 /var/log/cloud-init-output.log`.
- **`kc` says "no _work checkout"**: the runner never ran a job —
  trigger a deploy first (step 4); the checkout appears under
  `/opt/botforge/runners/<env>/_work/`.
- **Deploy stays pending, nothing notifies**: run `make doctor` (or
  `make diagnose-deploy-<env>`) from a clone *before* checking the
  runner — a stale run can hold the `deploy-<env>` concurrency group
  while the runner is healthy and idle.
- **Runner offline**: `cd /opt/botforge/runners/<env> && sudo ./svc.sh
  status`, restart with `sudo ./svc.sh start`.
- **Runner never goes Idle / service fails to start**: wrong file owner
  — `config.sh` must run as `botforge`. Fix with `sudo chown -R
  botforge:botforge /opt/botforge/runners/<env>`, then `sudo ./svc.sh
  start`; check `sudo journalctl -u actions.runner.* -e`.
- **`deploy.sh` says `DISCORD_TOKEN is not set`**: the GitHub
  environment of that env has no `DISCORD_TOKEN` secret (step 3).
- **Health gate fails and rolls back**: `kcl <env> botforge-bot` — the
  usual causes are an invalid token or an image-pull rate limit.
- **Permission denied from Docker**: `usermod -aG docker botforge` ran
  but your shell predates it — switch again with `sudo -iu botforge`.
- **Known pitfalls from past sessions**: Discord throttling ~2 h after
  intensive provisioning; `systemd-resolved` DNS quirks; the
  `/opt/botforge/data/<env>` bind mounts survive a hosting reset **by
  design** (that is the data).

## Glossary (first-timer)

- **Instance / VM / hosting server**: the virtual server you rent from a
  cloud provider. It has an IP address and you connect to it with `ssh`.
- **cloud-init / user-data**: a script you hand to the provider at
  instance creation; it runs automatically at first boot. Our block
  installs Docker, the `botforge` user, the firewall and the folders.
- **Self-hosted runner**: a small program on the server that executes
  GitHub Actions jobs. One per environment, labeled `botforge,env-<env>`.
- **Registration token**: a one-time, 1-hour password GitHub gives you to
  attach a runner to the repo. Shown once — copy it immediately.
- **Environment** (`test`, `dev-merlin`, …): one isolated stack (bot +
  MongoDB + Redis) on the server, with its own runner, GitHub secrets and
  `deploy/<env>` state branch.
- **Secret vs variable** (GitHub): a secret (e.g. `DISCORD_TOKEN`) is
  encrypted and only injected into deploy jobs — never displayed, never
  written on the server. A variable (e.g. `BOT_ADMINS`) is a plain
  non-secret setting.
- **State branch `deploy/<env>`**: a git branch that holds the exact
  image pinned for that env. Pushing to it = deploying that image.
- **Deploy**: running the `Deploy environment` workflow in the Actions tab;
  the runner on the server pulls the pinned image and starts the stack.

## Out of scope — lot 4

The laptop CLI (`vpsctl`: bootstrap / diagnose / start / stop / restart
/ status / logs against the hosting from your own machine, configured only
through a `~/.ssh/config` alias) is **not** part of this guide — it is
tracked in jj-guild/botforge-services#349.


## See also

- [RUNNER.md](RUNNER.md) — manual runner install/uninstall cheat-sheet
  (the raw commands behind `add-env.sh`)
- [ENVIRONMENTS.md](ENVIRONMENTS.md) — environment matrix + add-an-env
  checklist
- [DEPLOYMENT.md](DEPLOYMENT.md) — the deploy chain
- jj-guild/botforge-infra#5 — monitoring (resource usage, alerts)
