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
  `/opt/botforge/backups/<env>/` (deployment backups) and
  `/opt/botforge/envs/<env>/{mongo,redis}` (bind-mount targets — they
  survive a `docker compose down --volumes` reset).
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

- If the creation form has a **user data / cloud-init** field → paste the **`#cloud-config` block from §1 below** there (first line `#cloud-config`; set the runner version to the one shown on the Runners page).
- **No such field (OVH Public Cloud has none)** → skip it; the one-liner in step 2 does the exact same thing over SSH.

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
# (runner version differs from 2.337.0 -> insert: | sed 's/2\.337\.0/NEW/' before 'sudo bash')
# If you DID paste the cloud-init block: instead check it ran:
#   sudo cloud-init status --wait   # Expected: "status: done"
ls /opt/botforge/bin              # Expected: bootstrap.sh install-runner.sh add-env.sh
docker --version && docker compose version
docker run hello-world            # Expected: "Hello from Docker!"
id botforge                       # Expected: groups=…(docker)
sudo ufw status verbose           # Expected: Status: active, OpenSSH ALLOW
```

<details><summary>First time? what just happened</summary>

cloud-init ran the block you pasted at creation: it installed the packages, Docker, the `botforge` user (in the `docker` group, no password/sudo), enabled the firewall (SSH only — the stack exposes no public port), created `/opt/botforge/{bin,backups,runners,envs}`, downloaded the pinned runner tarball, and wrote the `kc`/`kcl` aliases (`/etc/profile.d/botforge.sh`, active at the **next** login).

</details>

#### 3. Register one runner per env — line by line

Token (shown **once**, valid **1 h**) — UI: <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new> (Settings → Actions → Runners → New self-hosted runner, Linux/x64), or API (scriptable with any HTTP client):

```bash
REG='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$REG" --jq '.token'
```

Then, **on the server**, exactly the commands GitHub prints on that page:

```bash
# Download
# Create a folder
$ mkdir actions-runner && cd actions-runner
# Download the latest runner package
$ curl -o actions-runner-linux-x64-2.338.2.tar.gz -L https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
# Optional: Validate the hash
$ echo "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40  actions-runner-linux-x64-2.338.2.tar.gz" | shasum -a 256 -c
# Extract the installer
$ tar xzf ./actions-runner-linux-x64-2.338.2.tar.gz
Configure
# Create the runner and start the configuration experience
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN>
# Last step, run it!
$ ./run.sh
```

(Use the runner version currently shown on the Runners page and your fresh `<TOKEN>`.)

After GitHub's block, our per-env settings (labels the deploy workflows route on; service so it survives reboots):

```bash
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN> --labels botforge,env-test
$ sudo ./svc.sh install && sudo ./svc.sh start
# equivalently: sudo /opt/botforge/bin/add-env.sh test --token <TOKEN>
```

Repeat per env (`test`, `dev-merlin`, `dev-drasah`…) with a **fresh token each time**.

**Verify:** Runners page → each env runner **Idle** (green), labels `self-hosted, botforge, env-<env>`; on the server `cd /opt/botforge/runners/<env> && sudo ./svc.sh status` → active (running).

<details><summary>First time? why a token, why labels</summary>

- The token is a one-time, 1-hour password that attaches a runner to the repo — GitHub shows it once, so copy it immediately and use it within the hour.
- Labels are how workflows pick the right runner: our deploy workflows require `self-hosted, botforge, env-<env>`.
- `svc.sh install` makes it a systemd service, so it restarts on reboot; `run.sh` is only for a quick manual test.

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

Add an env later on the same server: `sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>` (fresh token) + step 4. Nothing else to redo.

Validate each env before the next (`scripts/diagnose_env.sh` + `/status` in Discord). Order: **merlin → test → prod** (prod only at a release promotion).

#### 7. Daily ops

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

More: §8 Troubleshooting below.

---

## 0. Prerequisites

- A cloud provider account (any: OVH Public Cloud, Scaleway, Hetzner,
  DigitalOcean…) and a hosting instance (VM) with **Debian 13 (trixie)**
  (Ubuntu 26.04 LTS also works — the cloud-init block auto-detects the
  distro for the Docker apt repo via `/etc/os-release`), at least
  **2 GB RAM / 20 GB disk**.
- An **SSH key pair** on your computer. If you don't have one yet:
  `ssh-keygen -t ed25519 -C "you@example.com"` (Enter to accept the
  defaults), then copy the public key with `cat ~/.ssh/id_ed25519.pub`.
  You paste the **public** key at instance creation; the private key
  stays on your computer and is what lets you `ssh` in.
- Per environment, the env's **Discord bot token** (Discord developer
  portal → your application → Bot → Reset Token → copy) and the
  **Discord user IDs** of its operators (Discord → Settings → Advanced →
  Developer Mode → right-click a user → Copy ID).
- On GitHub (`jj-guild/botforge-infra`), per environment you
  will host:
  - a **GitHub environment** named `<env>` — created in step 3 with its
    secrets;
  - a **runner registration token**: Settings → Actions → Runners → New
    self-hosted runner → Linux/x64 (the token is valid **1 hour**).

## 1. Provision the hosting with cloud-init

Create the instance and paste the following block in the provider's
**user data / cloud-init** field, then boot. Replace `2.337.0` with the
runner version currently shown on the Runners page.


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
      mkdir -p /opt/botforge/bin /opt/botforge/backups /opt/botforge/runners /opt/botforge/envs
      chown -R botforge:botforge /opt/botforge

      # --- pinned runner binary, downloaded ONCE, shared by every env ---
      RUNNER_VERSION="2.337.0"  # <- version shown on the Runners page
      echo "$RUNNER_VERSION" > /opt/botforge/runners/.runner-version
      curl -fsSLo "/opt/botforge/runners/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
      chown -R botforge:botforge /opt/botforge/runners
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
  - path: /opt/botforge/bin/add-env.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Add one environment to a provisioned hosting: per-env dirs + runner
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
runcmd:
  - bash /opt/botforge/bin/bootstrap.sh
```

What the boot installs: the base libraries, Docker Engine + Compose,
`ufw` (SSH only), the `botforge` service user (no password, no sudo,
docker group), the `/opt/botforge/{bin,backups,runners,envs}` layout,
the pinned runner tarball (shared by all environments), the helper
scripts `/opt/botforge/bin/{bootstrap,install-runner,add-env}.sh`, and
the `kc` / `kcl` shell aliases via `/etc/profile.d/botforge.sh`.

**Verify** (first ssh login):

```bash
ssh <host>                           # e.g. ssh debian@203.0.113.10 (user = image name)
sudo cloud-init status --wait        # Expected at the end: "status: done"
docker run hello-world               # Expected: "Hello from Docker!"
docker compose version               # Expected: Docker Compose version v2…
ls /opt/botforge/bin                 # Expected: bootstrap.sh install-runner.sh add-env.sh
sudo -u botforge docker ps           # Expected: empty list, no permission error
```

The aliases load on the **next** login (profile.d): `exit`, reconnect,
then `type kc kcl`.

## 2. Register the runner(s) — line by line, one per environment

Before the commands: fetch a registration token. Either on the Runners
page (*Settings → Actions → Runners → New self-hosted runner*, Linux/x64
— <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>),
or via API (the token is shown once and is valid **1 hour**):

```bash
REG='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$REG" --jq '.token'
```

Then, on the hosting, exactly the commands GitHub prints on that page:

```bash
# Download
# Create a folder
$ mkdir actions-runner && cd actions-runner
# Download the latest runner package
$ curl -o actions-runner-linux-x64-2.338.2.tar.gz -L https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
# Optional: Validate the hash
$ echo "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40  actions-runner-linux-x64-2.338.2.tar.gz" | shasum -a 256 -c
# Extract the installer
$ tar xzf ./actions-runner-linux-x64-2.338.2.tar.gz
Configure
# Create the runner and start the configuration experience
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN>
# Last step, run it!
$ ./run.sh
```

(Use the runner version currently shown on the Runners page, and the
fresh token from above.)

After GitHub's block, our per-environment specifics — labels
`botforge,env-<env>`, install as a systemd service, per-env directory
under `/opt/botforge/runners/<env>/` (all of this is also wrapped by
`/opt/botforge/bin/add-env.sh <env> --token <TOKEN>`):

```bash
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN> --labels botforge,env-test
$ sudo ./svc.sh install && sudo ./svc.sh start
# or equivalently: sudo /opt/botforge/bin/add-env.sh test --token <TOKEN>
```

**Verify** — every env runner must be online/Idle with the right labels:

```bash
gh api /repos/jj-guild/botforge-infra/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
# or the Runners page: each env runner Idle (green),
# labels self-hosted, botforge, env-<env>
cd /opt/botforge/runners/<env> && sudo ./svc.sh status
```


## 3. GitHub environments and secrets (per environment)

On `jj-guild/botforge-infra`: **Settings → Environments →
`<env>`** — add the environment **secret** `DISCORD_TOKEN` (that
environment's bot token, from the Discord developer portal) and the
environment **variable** `BOT_ADMINS` (comma-separated Discord user IDs
of that bot's operators). Repeat per environment (`test`, `dev-merlin`,
…). Nothing secret is ever written to the hosting — the runner picks the
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
docker ps --filter name=botforge
# botforge-bot, botforge-mongo, botforge-redis must all show (healthy)
```

## 5. Adding an environment later

Environments are data (see [ENVIRONMENTS.md](ENVIRONMENTS.md)): one
`envs/<name>/` manifest + state, one `deploy/<name>` state branch, one
GitHub environment, one runner label. On a hosting provisioned with this
guide, the hosting part is a single command:

```bash
sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>
```

…then create the GitHub environment with its secrets (step 3) and the
repo data (manifest + `deploy/<env>` branch) per the
[ENVIRONMENTS.md](ENVIRONMENTS.md) checklist. Existing environments on
the same hosting are untouched — same scripts, same paths, shared tarball.

## 6. Daily operation — the aliases

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

## 7. Naming reference (current state)

- Org: `jj-guild`. Repos: `botforge` (docs), `botforge-services` (code),
  `botforge-infra` (this repo), `visual-generator`.
- Images: `ghcr.io/jj-guild/botforge-services:<tag>`.
- Git remotes and `gh api /repos/jj-guild/…` paths use the names above.
- Runner registration `--url`: `https://github.com/jj-guild/botforge-infra`.
- Runner labels: `botforge`, `env-<env>`. State branches: `deploy/<env>`.
- Hosting user/paths: `botforge`, `/opt/botforge/…`. Image env var:
  `BOTFORGE_IMAGE` (read from `envs/<env>/state/botforge-bot.yml`).


## 8. Troubleshooting

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
  `/opt/botforge/envs/<env>` bind mounts survive a hosting reset **by
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
