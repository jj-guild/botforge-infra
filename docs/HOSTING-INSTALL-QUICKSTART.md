# Hosting install — quickstart (Debian 13)

Straightforward path to a ready deployment target. Full reference:
[HOSTING-SETUP.md](HOSTING-SETUP.md) (cloud-init block, per-env details,
troubleshooting). Tracked by jj-guild/botforge-services#241 / #331.

## 0. What you need before starting

- A hosting provider account (any cloud: OVH Public Cloud, Hetzner,
  Scaleway, DigitalOcean…) + an **SSH key pair** (you keep the private
  key; paste the **public** key at instance creation).
- GitHub access to `jj-guild/botforge-infra` (Settings → Actions →
  Runners, and Settings → Environments).
- Per environment (`test`, `dev-merlin`, `dev-drasah`…): the Discord bot
  token for that env (Discord developer portal).

## 1. Create the instance with the cloud-init block

Create the instance (OS: **Debian 13**, ≥ **2 GB RAM / 20 GB disk**, your
**public** SSH key) and paste the `#cloud-config` block from
[HOSTING-SETUP.md §1](HOSTING-SETUP.md) into the provider's
**user data / cloud-init** field, then boot. Replace the runner version
placeholder with the version shown on the Runners page.

At first boot this installs: base libraries, Docker Engine + Compose,
`ufw` (SSH only), the `botforge` service user (docker group), the
`/opt/botforge/{bin,backups,runners,envs}` layout, the pinned runner
tarball, the helper scripts `/opt/botforge/bin/{bootstrap,install-runner,add-env}.sh`,
and the `kc` / `kcl` aliases via `/etc/profile.d/botforge.sh`.

**Verify** (first SSH login, no `| head`):

```bash
ssh <user>@<instance-ip>
sudo cloud-init status --wait        # ends with "done"
ls /opt/botforge/bin                 # bootstrap.sh install-runner.sh add-env.sh
docker --version
id botforge                          # must list group docker
sudo ufw status verbose              # active, OpenSSH allowed
```

## 2. Register one runner per environment — line by line

Fetch a registration token (shown once, valid **1 hour**): on
<https://github.com/jj-guild/botforge-infra/settings/actions/runners/new>
(Settings → Actions → Runners → New self-hosted runner, Linux/x64), or via
API (scriptable with any HTTP client):

```bash
REG='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$REG" --jq '.token'
```

Then on the hosting, exactly the commands GitHub prints on that page:

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

Then our per-environment specifics (labels, systemd service, per-env
directory — also wrapped by `sudo /opt/botforge/bin/add-env.sh <env>
--token <TOKEN>`):

```bash
$ ./config.sh --url https://github.com/jj-guild/botforge-infra --token <TOKEN> --labels botforge,env-test
$ sudo ./svc.sh install && sudo ./svc.sh start
```

Repeat per environment (`test`, `dev-merlin`, `dev-drasah`…) with a fresh
token each time. **Verify**: Runners page → each env runner **Idle**
(green), labels `self-hosted, botforge, env-<env>`; on the hosting:
`cd /opt/botforge/runners/<env> && sudo ./svc.sh status`.

## 3. GitHub environment secrets (per env)

`jj-guild/botforge-infra` → **Settings → Environments → `<env>`**:

- secret **`DISCORD_TOKEN`** = that env's Discord bot token
- variable **`BOT_ADMINS`** = comma-separated Discord user IDs of the
  env's operators

Nothing secret is ever stored on the hosting.

## 4. First deployment

Actions tab → **Deploy environment** → Run workflow → environment
`test`. Verify on the hosting: `docker ps --filter name=botforge`
(`botforge-bot`, `botforge-mongo`, `botforge-redis` healthy).

## 5. Env order after the hosting reinstall

Validate each env (`scripts/diagnose_env.sh` on the runner workdir +
`/status` in Discord) before the next: **merlin → test → prod** (prod at
release promotion).

## Daily ops

`kc <env> ps`, `kcl <env> botforge-bot` (aliases from
`/etc/profile.d/botforge.sh`; `BOTFORGE_IMAGE` is read from the pinned
`envs/<env>/state/botforge-bot.yml`).
