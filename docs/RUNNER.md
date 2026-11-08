# Runner cheat-sheet — install & uninstall

On a hosting provisioned by cloud-init ([HOSTING-SETUP.md](HOSTING-SETUP.md)), prefer
`sudo /opt/botforge/bin/add-env.sh <env> --token <TOKEN>` — the commands
below are its manual equivalent.

Every command, in order, nothing else. One runner per environment,
always in `/opt/botforge/runners/<env>/` (replace `<env>` throughout:
`test`, `prod`, `drasah`, …). The runner tarball is downloaded **once**
to `/opt/botforge/runners/actions-runner-linux-x64-<VERSION>.tar.gz`,
next to the environment directories, and extracted into each new
environment — several environments share the same archive.

Context: `principal` = your admin login on the hosting (sudo),
`botforge` = the service user that owns `/opt/botforge`.

## Install

```bash
# 0. on GitHub (not on the hosting): open the Runners page and copy the
#    Download command + registration token
#    Settings → Actions → Runners → New self-hosted runner (Linux / x64)

# 1. as botforge — download the tarball ONCE, then configure
sudo -iu botforge
cd /opt/botforge/runners
curl -o actions-runner-linux-x64-<VERSION>.tar.gz -L \
     https://github.com/actions/runner/releases/download/v<VERSION>/actions-runner-linux-x64-<VERSION>.tar.gz
# <VERSION> = whatever GitHub's Runners page currently shows (e.g. 2.337.0)
mkdir -p <env> && cd <env>
tar xzf ../actions-runner-linux-x64-<VERSION>.tar.gz
./config.sh --url https://github.com/jj-guild/botforge-infra \
            --token <TOKEN> --labels botforge,env-<env>
exit

# 2. as principal — install and start the service
cd /opt/botforge/runners/<env>
sudo ./svc.sh install botforge
sudo ./svc.sh start
```

Verify: the runner shows **Idle** (green) on the GitHub Runners page,
with labels `self-hosted`, `botforge`, `env-<env>`.

## Uninstall

```bash
# 1. as principal — stop and remove the service
cd /opt/botforge/runners/<env>
sudo ./svc.sh uninstall

# 2. as botforge — deregister the runner from GitHub
#    (use a fresh registration token from the Runners page)
sudo -iu botforge
cd /opt/botforge/runners/<env>
./config.sh remove --token <TOKEN>
exit

# 3. as principal — optionally remove the directory
sudo rm -rf /opt/botforge/runners/<env>
```

## Quick checks

```bash
# service status (as principal, in the runner directory)
cd /opt/botforge/runners/<env> && sudo ./svc.sh status
# service logs
sudo journalctl -u actions.runner.botforge-...-<env> -e
# registered runners on the repo (from anywhere with gh)
gh api /repos/jj-guild/botforge-infra/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Full narrative guide with security context: [HOSTING-SETUP.md](HOSTING-SETUP.md).
