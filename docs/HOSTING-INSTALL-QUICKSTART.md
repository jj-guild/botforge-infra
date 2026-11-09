# Hosting install — quickstart (first time? start here)

This page gets you from zero to a working deployment target, step by step,
with the exact commands and the output you should expect at each step.
No prior experience with servers, GitHub Actions or Docker is assumed.
Budget about **30–45 minutes**.

Full reference (details, per-env options, troubleshooting):
[HOSTING-SETUP.md](HOSTING-SETUP.md).

## What you are going to build (in plain words)

- A **hosting instance** = a small virtual server in the cloud (a "VM").
- **cloud-init** = a script you give the provider at creation; it runs
  automatically at first boot and installs everything (Docker, the
  `botforge` user, firewall, folders…). You never run it by hand.
- A **self-hosted GitHub Actions runner** = a small program on that
  server that executes the deploy jobs GitHub sends it.
- An **environment** (`test`, `dev-merlin`…) = one isolated copy of the
  whole stack (bot + MongoDB + Redis) on that server, with its own
  runner, its own secrets, its own `deploy/<env>` state branch.
- A **secret** (e.g. `DISCORD_TOKEN`) is a password-like value stored in
  GitHub, injected only at deploy time — **never written on the server**.
  A **variable** (e.g. `BOT_ADMINS`) is a plain non-secret setting.

**End result:** the server runs the bot stack, GitHub can deploy to it on
demand, and you can watch logs with two short commands (`kc`, `kcl`).

## 0. Prerequisites — get these first

| You need | How to get it |
| --- | --- |
| A cloud provider account (OVH Public Cloud, Hetzner, Scaleway, DigitalOcean…) | Sign up on the provider's site; you'll need a payment method |
| An **SSH key pair** | On your computer, run: `ssh-keygen -t ed25519 -C "you@example.com"` (press Enter to accept defaults). Your **public** key is the file `~/.ssh/id_ed25519.pub` — print it with `cat ~/.ssh/id_ed25519.pub` and copy it |
| Access to the GitHub repo `jj-guild/botforge-infra` | Ask the maintainer to add you (you need Settings access for runners/environments) |
| Per environment: the **Discord bot token** | Discord developer portal → Your Application → Bot → Reset Token → copy. (One token per environment/bot.) |
| Per environment: the **Discord user IDs** of the operators (`BOT_ADMINS`) | In Discord, enable Developer Mode (Settings → Advanced), right-click each user → Copy ID |

## 1. Create the instance, with the cloud-init block

In your provider's console, create a new instance/VM:

- **OS image: Debian 13** (Ubuntu 26.04 LTS also works)
- **Size: at least 2 GB RAM / 20 GB disk**
- **SSH key: paste your public key** (`~/.ssh/id_ed25519.pub`)
- **User data / cloud-init field**: paste the whole `#cloud-config` block
  from [HOSTING-SETUP.md §1](HOSTING-SETUP.md) (first line must be
  `#cloud-config`). Replace the runner version placeholder with the
  version shown on the GitHub Runners page.

Then start the instance. **Expected:** the instance shows as
running/active with a public IP address.

## 2. First SSH login — verify the bootstrap ran

```bash
ssh debian@<instance-ip>     # the login user is the image name (debian, ubuntu…); it has sudo
```

(If the provider set a different user, use that one; `root` also works
with `ssh root@<instance-ip>`.)

Then check that the automatic install finished:

```bash
sudo cloud-init status --wait     # Expected, at the end: "status: done"
ls /opt/botforge/bin              # Expected: bootstrap.sh  install-runner.sh  add-env.sh
docker --version                  # Expected: Docker version 2x…
id botforge                       # Expected: uid=…(botforge) … groups=…(docker)
sudo ufw status verbose           # Expected: "Status: active", rule "OpenSSH" (or 22/tcp) ALLOW
```

If `cloud-init status` is not `done` yet, wait a minute and retry.
The bootstrap installs Docker, the `botforge` user, the firewall and the
`/opt/botforge/...` folders — all automatic.

## 3. Register one runner per environment — line by line

A runner registration token is shown **once** and is valid **1 hour**.
Get it either:

- on the page <https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>
  (GitHub → repo `jj-guild/botforge-infra` → **Settings → Actions → Runners → New self-hosted runner**, choose **Linux/x64**), or
- via API (scriptable with any HTTP client):

```bash
REG='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$REG" --jq '.token'
```

Then, **on the server** (still in your SSH session), run exactly the
commands GitHub prints on that page:

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

(Use the runner version currently shown on the Runners page, and your
fresh `<TOKEN>`.)

After GitHub's block, our per-environment settings — the labels the
deploy workflows route on, and installing the runner as a service so it
survives reboots:

```bash
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN> --labels botforge,env-test
$ sudo ./svc.sh install && sudo ./svc.sh start
```

(Equivalently, the bootstrap prepared a wrapper:
`sudo /opt/botforge/bin/add-env.sh test --token <TOKEN>`.)

Repeat **per environment** (`test`, `dev-merlin`, `dev-drasah`…) with a
**fresh token each time** (they expire after 1 h).

**Verify:**

- GitHub → Runners page: each env runner shows **Idle** (green) with
  labels `self-hosted, botforge, env-<env>`.
- On the server: `cd /opt/botforge/runners/<env> && sudo ./svc.sh status`
  → Expected: active (running).

## 4. GitHub environment secrets (per env)

GitHub → `jj-guild/botforge-infra` → **Settings → Environments → `<env>` → Add secret / Add variable**:

- **Secret** `DISCORD_TOKEN` = that env's Discord bot token
- **Variable** `BOT_ADMINS` = comma-separated Discord user IDs

Repeat for each environment. Nothing secret is ever stored on the server.

## 5. First deployment

GitHub → repo `jj-guild/botforge-infra` → **Actions** tab → workflow
**Deploy environment** → **Run workflow** → environment: `test`.

**Expected:** the workflow run turns green in a few minutes. On the
server:

```bash
docker ps --filter name=botforge
# Expected: botforge-bot, botforge-mongo, botforge-redis — all "healthy"/Up
```

And in Discord: the test bot answers (e.g. `/status`).

## 6. Adding more environments, and the env order

- Add an env later: same server, `sudo /opt/botforge/bin/add-env.sh
  <env> --token <TOKEN>` + the GitHub environment from step 4. Nothing
  else to redo.
- After a full reinstall, validate each env before the next one
  (`scripts/diagnose_env.sh` on the runner's workdir + `/status` in
  Discord). Order: **merlin → test → prod** (prod only at a release
  promotion).

## 7. Daily operations

On the server, the aliases load at each new login:

```bash
kc <env> ps            # what's running in that env
kcl <env> botforge-bot # follow the bot's logs
```

(`kc` automatically sets `BOTFORGE_IMAGE` from the pinned state file
`envs/<env>/state/botforge-bot.yml` — no manual env vars needed.)

## If something goes wrong

- **Token rejected/expired** → fetch a new one (valid 1 h) and rerun
  `./config.sh …`.
- **`cloud-init status` not done** → wait; check
  `sudo tail -n 50 /var/log/cloud-init-output.log`.
- **Runner shows Offline** → on the server:
  `cd /opt/botforge/runners/<env> && sudo ./svc.sh status` then
  `sudo systemctl status actions.runner.*`.
- **Deploy workflow stays pending** → the runner label doesn't match;
  check labels on the Runners page (`self-hosted, botforge, env-<env>`).
- More: [HOSTING-SETUP.md §8 Troubleshooting](HOSTING-SETUP.md).
