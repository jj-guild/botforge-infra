# VPS install — quickstart (OVH Public Cloud, Debian 13)

Straightforward path to a ready deployment target. Full reference:
[VPS-SETUP.md](VPS-SETUP.md) (cloud-init block, per-env details,
troubleshooting). Tracked by jj-guild/botforge-services#241 / #331.

## 0. What you need before starting

- OVH Public Cloud project + an **SSH key pair** (you keep the private
  key; paste the **public** key at instance creation).
- GitHub access to `jj-guild/botforge-infra` (Settings → Actions →
  Runners, and Settings → Environments).
- Per environment (`test`, `dev-merlin`, `dev-drasah`…): the Discord bot
  token for that env (Discord developer portal).

## 1. Create the instance

OVH Control Panel → Public Cloud → your project → **Compute → Create an
instance**:

- OS: **Debian 13**
- Flavor: ≥ **2 GB RAM / 20 GB disk**
- SSH key: paste your **public** key (or select an imported key pair)
- Note: the Control Panel has **no user-data/cloud-init field** (OVH
  Public Cloud is OpenStack; user-data is creation-time only, via
  `openstack server create --user-data …` — see VPS-SETUP.md §1). So
  create the instance plain, then use step 2.

## 2. Bootstrap the VPS (SSH as root)

```bash
ssh <user>@<instance-ip>          # OVH cloud image user (e.g. debian), it has sudo
curl -fsSL https://raw.githubusercontent.com/jj-guild/botforge-infra/main/scripts/vps/bootstrap-flat.sh | sudo bash
```

If the runner version on the GitHub Runners page differs from `2.337.0`:
`curl … | sed 's/2\.337\.0/NEW_VERSION/' | sudo bash`

Takes a few minutes (apt, Docker, user, firewall, layout, runner
tarball). **Verify** (no `| head`):

```bash
ls /opt/botforge/bin                 # bootstrap.sh install-runner.sh add-env.sh
sudo cat /opt/botforge/runners/.runner-version
docker --version
id botforge                          # must list group docker
sudo ufw status verbose              # active, OpenSSH allowed
```

## 3. Register one runner per environment

GitHub → `jj-guild/botforge-infra` → **Settings → Actions → Runners →
New self-hosted runner** (Linux/x64). The token is shown **once**, valid
**1 hour**. Same thing via API (handy from a script) — CLI:

```bash
GH_API='repos/jj-guild/botforge-infra/actions/runners/registration-token'
gh api -X POST "$GH_API" --jq '.token'
```

or in JS with octokit:

```js
const { data } = await octokit.request(
  "POST /repos/{owner}/{repo}/actions/runners/registration-token",
  { owner: "jj-guild", repo: "botforge-infra" });
console.log(data.token); // valid 1 hour
```

On the VPS, immediately:

```bash
sudo /opt/botforge/bin/add-env.sh test --token <TOKEN>
sudo /opt/botforge/bin/add-env.sh dev-merlin --token <TOKEN>   # fresh token each time
sudo /opt/botforge/bin/add-env.sh dev-drasah --token <TOKEN>
```

**Verify**: Runners page → each env runner **Idle** (green), labels
`self-hosted, botforge, env-<env>`. On the VPS:
`cd /opt/botforge/runners/test && sudo ./svc.sh status`

## 4. GitHub environment secrets (per env)

`jj-guild/botforge-infra` → **Settings → Environments → `<env>`**:

- secret **`DISCORD_TOKEN`** = that env's Discord bot token
- variable **`BOT_ADMINS`** = comma-separated Discord user IDs of the
  env's operators

Nothing secret is ever stored on the VPS.

## 5. First deployment

Actions tab → **Deploy environment** → Run workflow → environment
`test`. Verify on the VPS: `docker ps --filter name=botforge`
(`botforge-bot`, `botforge-mongo`, `botforge-redis` healthy).

## 6. Env order after the rename reinstall

Validate each env (`scripts/diagnose_env.sh` on the runner workdir +
`/status` in Discord) before the next: **merlin → test → prod** (prod at
release promotion).

## Daily ops

`kc <env> ps`, `kcl <env> botforge-bot` (aliases from
`/etc/profile.d/botforge.sh`; `BOTFORGE_IMAGE` is read from the pinned
`envs/<env>/state/botforge-bot.yml`).
