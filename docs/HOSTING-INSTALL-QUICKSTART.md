# Hosting install — quickstart

Two ways to read this page:
- **You know what you're doing** → use the **Fast path** below (commands
  only, expected output in comments). ~15 min.
- **First time** → the Fast path works as-is; expand the
  `<details>` explanations under each step for the plain-words version.

Full reference + glossary: [HOSTING-SETUP.md](HOSTING-SETUP.md).
Tracked by jj-guild/botforge-services#241 / #331.

---

## Fast path

### 0. Prereqs

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

### 1. Create the instance

Provider console → new instance: **Debian 13** (Ubuntu 26.04 LTS ok), **≥ 2 GB RAM / 20 GB disk**, paste your **public** SSH key, and paste the **`#cloud-config` block from [HOSTING-SETUP.md §1](HOSTING-SETUP.md)** into the **user data / cloud-init** field (first line must be `#cloud-config`; set the runner version to the one shown on the Runners page). Boot.

<details><summary>First time? where exactly</summary>

- OVH Public Cloud: project → Compute → Create an instance → OS "Debian 13", flavor ≥ 2 GB, paste the public key under "SSH key". The user-data field is the "Configuration"/advanced section of the creation form.
- The instance gets a public IP — you'll ssh into it in the next step. Login user = image name (usually `debian`).

</details>

### 2. First SSH login — verify the bootstrap

```bash
ssh debian@<instance-ip>
sudo cloud-init status --wait     # Expected, at the end: "status: done"
ls /opt/botforge/bin              # Expected: bootstrap.sh install-runner.sh add-env.sh
docker --version && docker compose version
docker run hello-world            # Expected: "Hello from Docker!"
id botforge                       # Expected: groups=…(docker)
sudo ufw status verbose           # Expected: Status: active, OpenSSH ALLOW
```

<details><summary>First time? what just happened</summary>

cloud-init ran the block you pasted at creation: it installed the packages, Docker, the `botforge` user (in the `docker` group, no password/sudo), enabled the firewall (SSH only — the stack exposes no public port), created `/opt/botforge/{bin,backups,runners,envs}`, downloaded the pinned runner tarball, and wrote the `kc`/`kcl` aliases (`/etc/profile.d/botforge.sh`, active at the **next** login).

</details>

### 3. Register one runner per env — line by line

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

### 4. GitHub environment secrets (per env)

Repo `jj-guild/botforge-infra` → **Settings → Environments → `<env>`**:

- **Secret** `DISCORD_TOKEN` = that env's bot token
- **Variable** `BOT_ADMINS` = comma-separated operator Discord user IDs

Nothing secret is ever stored on the server.

### 5. First deployment

Repo → **Actions** → **Deploy environment** → **Run workflow** → environment `test`. Expected: green in a few minutes. On the server:

```bash
docker ps --filter name=botforge   # Expected: botforge-bot, botforge-mongo, botforge-redis — Up/healthy
```

And in Discord: the test bot answers `/status`.

### 6. More envs + order after a reinstall

Add an env later on the same server: `sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>` (fresh token) + step 4. Nothing else to redo.

Validate each env before the next (`scripts/diagnose_env.sh` + `/status` in Discord). Order: **merlin → test → prod** (prod only at a release promotion).

### 7. Daily ops

```bash
kc <env> ps             # what's running in that env
kcl <env> botforge-bot  # follow the bot's logs
```

(`kc` sets `BOTFORGE_IMAGE` from the pinned `envs/<env>/state/botforge-bot.yml` automatically.)

### If something goes wrong

| Symptom | Fix |
| --- | --- |
| Token rejected/expired | fetch a new one (1 h validity), rerun `./config.sh …` |
| `cloud-init status` not `done` | wait; `sudo tail -n 50 /var/log/cloud-init-output.log` |
| Runner Offline on the Runners page | on the server: `cd /opt/botforge/runners/<env> && sudo ./svc.sh status` |
| Deploy workflow stays pending | label mismatch — check `self-hosted, botforge, env-<env>` on the runner |

More: [HOSTING-SETUP.md §8 Troubleshooting](HOSTING-SETUP.md).
