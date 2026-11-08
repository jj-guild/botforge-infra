# Environments

The BotForge platform runs the same stack in three kinds of environments:

- **test** and **prod** — the shared validation and production
  environments, deployed from pinned state on their `deploy/<env>` state
  branch;
- **personal environments** (`drasah`, `merlin`, …) — one per rostered
  user, mapped to their integration branch `vibe/<alias>/main`: the env
  runs whatever its user's integration branch head builds (**autopin**,
  no command needed). It is the user's sandbox: their bot, their Discord,
  their runner (see botforge `docs/CONVENTIONS.md` § *Integration
  branches*).

This page is the environment matrix; the deployment procedure lives in
[DEPLOYMENT.md](DEPLOYMENT.md).

| | test | prod |
| --- | --- | --- |
| Manifest | `envs/test/docker-compose.yml` | `envs/prod/docker-compose.yml` |
| Bot image | `ghcr.io/...` pinned by the state branch: `pr-<id>-<timestamp>-<sha>` for `/deploy`, `sha-<sha>` for main | `ghcr.io/...` released tag `vX.Y.Z` via `BOTFORGE_IMAGE` |
| Image pull policy | `missing` | `always` |
| Host | VPS (runner) | VPS (runner) |
| Secrets | GitHub environment secrets (injected by the runner) | GitHub environment secrets |
| MongoDB exposed ports | 27017 | — |
| Redis exposed ports | 6379 | — |

Personal environments publish the same debug ports with a per-env host
port (co-located envs on a shared VPS must not collide): `merlin` →
27018/6380, `drasah` → 27019/6381.
| Redis persistence | volume | volume + AOF |
| Bot memory limit | — | 512M |
| Deploy trigger | Push to the `deploy/test` state branch (written by the GitHub App from a `/deploy` PR comment, or redeployed at its current pin by a test-config change on main — the image is never swapped by a config change) | Push to the `deploy/prod` state branch (written by the release pipeline; the branch ruleset requires a PR — approving a prod deploy is merging it) |
| Pre-deploy backup | mandatory | mandatory |
| Env template | — (secrets live in GitHub environment `test`) | — (GitHub environment `prod`) |
| State branch | `deploy/test` (ADR-0018) | `deploy/prod` (ADR-0018) |
| Bot healthcheck | `/healthz` (compose + image) | `/healthz` (compose + image) |

## Configuration variables

Secrets are **never stored on the VPS**. They live in GitHub
*environment secrets* (Settings → Environments → `test` /
`prod` → Add environment secret) and the self-hosted runner injects them
into `docker compose` at deploy time. The manifests read them by name
and fail closed when one is missing.

| Variable | Description |
| -------- | ----------- |
| `DISCORD_TOKEN` | Discord bot token (required) |
| `BOT_ADMINS` | Comma-separated Discord user IDs of the bot operators (botforge-services#35), provisioned as an environment **variable**; empty means `/status` reports no operator |
| `BOTFORGE_DEPLOY_URL` | URL shown by the `/status` Services field: the `/deploy` deployment comment permalink, a tree link (`/tree/<sha>`) for main, the release URL for prod (empty → `n/a`) |
| `BOTFORGE_DEPLOY_LABEL` | Label shown by the `/status` Services field: `pr-<id>-<timestamp>-<sha>` for a PR deploy, `main@<sha>` for main, `vX.Y.Z` for a release (empty → package version) |
| `BOTFORGE_DEPLOY_RUN_URL` | URL of the deploy job shown by the `/status` Infra field — injected by the deploy workflow itself (`github.server_url/repository/actions/runs/<run_id>`), so the running bot links the exact job that deployed it |
| `BOTFORGE_DEPLOY_INFRA_LABEL` | Short label of the deployed infra state (`deploy/<env>@<sha>`), shown by the `/status` Infra field — injected by the deploy workflow |
| `BOTFORGE_DEPLOY_INFRA_URL` | Tree URL of the deployed infra state commit, the link behind `deploy/<env>@<sha>` |
| `BOTFORGE_DEPLOY_INFRA_COMMIT_TS` | Unix timestamp of the deployed infra state commit, exported by the deploy workflow from the pinned state checkout — the `Committed` relative time of the announcement Infra section, distinct from the `Deployed` run time |
| `BOTFORGE_DEPLOY_KIND` | Deploy kind for the typed `/status` links: `pr`, `main`, or `release` — written by the deploy pipelines in the pinned state file |
| `BOTFORGE_DEPLOY_REF` | Deploy reference for the typed link: PR number, short sha, or release tag |
| `BOTFORGE_DEPLOY_TREE_URL` | Tree URL behind the `tree` link of a main/release version |
| `BOTFORGE_DEPLOY_TS` | Unix timestamp of the image build/pin, written by the Pin state workflow — the `Built` relative time of the announcement Services section |
| `BOTFORGE_DEPLOY_COMMIT_TS` | Unix timestamp of the deployed services commit (its sha rides inside `deploy_tree_url`), resolved by the Pin state workflow via the GitHub API — the `Committed` relative time of the announcement Services section |
| `BOTFORGE_DEPLOY_RUN_NUMBER` | Number of the deploy job — renders as `Deployment #<n>` in the Deploy field |
| `BOTFORGE_DEPLOY_RUN_TS` | Unix timestamp of the deploy job start (relative Discord time in the Infra field) |
| `BOTFORGE_DEPLOY_IMAGE` | Pinned container image reference, exported by `scripts/deploy.sh` from the state file — rendered as the `Image` line of the `/status` Services field (links to the GHCR package page) |
| `BOTFORGE_DEPLOY_BRANCH` | Source branch of the deployed services commit (e.g. the PR branch, `main`), written by the deploy pipelines in the pinned state — rendered as the `Branch` line of the `/status` Services field |
| `BOTFORGE_DEPLOY_PR_TITLE` | Title of the pull request that triggered the deployment (empty for main/release deploys) — rendered in the `Pull-request #<n>` label of the `/status` Services field |
| `BOTFORGE_DEPLOY_ENV` | Environment name (`test`, `prod`) injected by the deploy workflow — the bot's startup announcement env badge and `/status` identity (botforge-infra#78 spec 1) |

| `MONGO_URI` | MongoDB connection string (overridden by compose inside the stack) |
| `MONGO_DB` | MongoDB database name |
| `REDIS_URI` | Redis connection string (overridden by compose inside the stack) |
| `LOG_LEVEL` | Python logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |
| `BOTFORGE_IMAGE` | **Prod only**: full bot image reference, e.g. `ghcr.io/jj-guild/botforge-services:v0.1.0` |

The compose manifests override `MONGO_URI` and `REDIS_URI` so the bot always
targets the in-stack services.

## Adding an environment (ADR-0018 checklist)

Environments are **data, not workflows**: one directory per environment
(`envs/<name>/` with its manifest and state), one `deploy/<name>` state
branch, one runner label, one GitHub environment. The deploy, sync,
re-pin, CI and rules-audit workflows all discover the environments
automatically — adding one is the checklist below, nothing else:

1. **Manifest**: `envs/<name>/docker-compose.yml` on `main` (copy the
   test one; the image is pinned by state, never a floating tag).
2. **Runner label**: the environment VPS's self-hosted runner carries
   `env-<name>` (see [VPS-SETUP.md](VPS-SETUP.md)) — one runner per VPS.
3. **State branch**: `deploy/<name>` cut from `main` with the initial
   state commit (`envs/<name>/state/botforge-bot.yml`); the deploy
   workflow reads the pinned image from it.
4. **GitHub environment**: create the `<name>` environment with its
   secrets/variables (`DISCORD_TOKEN`, `BOT_ADMINS`, …) and its
   reviewers — **the environment's required reviewers are who may
   deploy it** (e.g. only the developer and ops for prod; leave test
   envs open to collaborators).
5. **Branch ruleset**: protect `deploy/<name>` (no force-push, no
   deletion; PR required for prod-like environments — approving a
   production deployment is merging that PR).

For a **personal environment** (`<alias>`), steps 1–3 come as data
(the manifest is the test one; the state branch is created by the first
autopin) and the flow is simpler:

- **GitHub environment** `<alias>`: branch policy on `deploy/<alias>`,
  no required reviewers (it is the user's sandbox), secrets
  `DISCORD_TOKEN` + `BOT_ADMINS` of the user's own bot.
- **Runner**: label `env-<alias>` on the user's VPS (or the shared one
  for now).
- **Autopin**: a push to `vibe/<alias>/main` on botforge-services builds
  the image (`sha-<sha>`) and pins it on `deploy/<alias>`
  (`deploy_kind: integration`) — the pin push deploys the env. Diagnose
  the chain with `scripts/diagnose_env.sh <alias>` (human report) or
  `--flags` (grep-able FLAG lines; exit 1 when a BLOCK flag is raised).

Prod-like environments (released `vX.Y.Z` images only, never re-pinned
from a config change on main) are listed in `PROTECTED_ENVS` in
[deploy.yml](../.github/workflows/deploy.yml); everything else is
per-environment data.

## Keeping the state branches current (pipeline propagation)

The state branches are cut from `main` once, then evolve on their own:
the pipelines only ever touch `envs/<env>/state/botforge-bot.yml`, so
any change to a **deploy workflow, manifest or script merged on `main`
keeps running in its old revision on the state branch** until it is
propagated. A missed propagation is invisible — the deploy succeeds with
stale pipeline code (this is how `BOT_ADMINS` once read `secrets.*` on
`deploy/test` while `main` had moved to `vars.*` — `/status` showed no
admin).

Whenever a merge on `main` changes a deploy workflow, a `deploy/<env>/`
manifest or `scripts/deploy.sh`, it must be propagated to every state
branch. State branches carry their own state commits (and sync merges),
so this is a merge, not a fast-forward. Propagation is **automated**:

- the [Sync state branches](../.github/workflows/sync-state.yml) workflow
  merges `main` into each `deploy/<env>` on every push to `main` (no-op
  when the state branch already contains `main`);
- the [Pin state](../.github/workflows/pin-state.yml) workflow (the
  `/deploy` path) merges `main` in the same commit as the image pin,
  so a deployment can never run stale manifests either.

Adding an environment is adding it to both matrices. The manual
equivalent, for reference or recovery:

```
git fetch origin && git checkout deploy/<env>
git merge origin/main -m "deploy(<env>): sync state branch with main"
git push origin deploy/<env>
```

The sync push deploys with the unchanged pinned state — safe by design.
The `sync-state` workflow pushes with the `kingdoms-deployer` App token —
the same actor the deploy pipelines use to write the pinned state, and the
only non-admin actor in the `deploy/*` ruleset bypass lists.

**Single-writer design:** every writer to a `deploy/<env>` state branch
lives in this repository and shares one concurrency group,
`deploy-state-<env>` — pin-state.yml (image pins dispatched by the deploy
pipelines), sync-state.yml and the re-pin job of deploy.yml. GitHub
serializes them, so a pin can never race a sync (the historical "cannot
lock ref" failure); a pin also merges `main` into the state branch, so
deployments cannot run stale pipeline code. Known limit: only the latest
queued run of a group survives; a superseded sync is harmless — the next
push to `main` re-triggers it.

The rulesets (no force-push) keep the history auditable:
`git log main..deploy/<env>` shows exactly which state commits exist
beyond `main`. The [Branch and tag rules audit](#branch-and-tag-rules-audit)
workflow fails when a state branch drifts from `main`.

## Branch and tag rules (expected configuration)

The authoritative configuration lives on GitHub (Settings → Rules → Rule
sets); this table is the expected state, and the
**Branch and tag rules audit** workflow (`.github/workflows/rules-audit.yml`)
fails when reality drifts from it — run it on demand, or after every
ruleset change.

### botforge-infra

| Ref / scope | Ruleset | Rules | Required status checks |
| --- | --- | --- | --- |
| `main` | `main` | deletion, non-fast-forward, linear history, PR required (1 approval), status checks | the 6 infra checks (below) |
| `deploy/test` | `Deploy TEST` | deletion, non-fast-forward, linear history, status checks | the 6 infra checks (below) |
| `deploy/prod` (+ default branch) | `Deploy PROD` | deletion, non-fast-forward, linear history, PR required, status checks | the 6 infra checks (below) |

Infra required status checks (all three branch rulesets):

1. `Lint scripts and workflows`
2. `Validate compose manifests`
3. `Validate infrastructure files`
4. `Backup/restore round-trip test`
5. `Smoke test (test stack boot)`
6. `cla`

### botforge-services

| Ref / scope | Ruleset | Rules | Required status checks |
| --- | --- | --- | --- |
| `main` | `main` | deletion, non-fast-forward, linear history, PR required (1 approval), status checks | `Lint (ruff)`, `Typecheck (mypy strict)`, `Unit tests (pytest)`, `Validate and boot docker-compose.yml`, `Smoke test (bot image + MongoDB + Redis)`, `Discord smoke (real gateway via the CI/CD bot)`, `Build and test the image`, `Generate and check pydoc freshness`, `cla` |
| tags `v*.*.*` | `release-tags` | deletion, non-fast-forward | — |

The `release-tags` ruleset is **required for prod**: it lets anyone push a
`vX.Y.Z` tag (rulesets cannot block tag *creation* by name for non-admins),
but forbids deleting or force-updating one — a release is immutable once
cut. The Docker workflow publishes the `vX.Y.Z` image only for the
`v*.*.*` tag classifier.

### botforge

| Ref / scope | Ruleset | Rules | Required status checks |
| --- | --- | --- | --- |
| `main` | `main` | deletion, non-fast-forward, linear history, PR required (1 approval), status checks | `cla`, `check` (docs validation) |

## Access and trigger protections (as configured on GitHub, 2026-09)

Who may deploy what is enforced by GitHub at three layers. The
environments below gate **secret access and job execution**; the Actions
policy gates **who may trigger the workflows** (see
[DEPLOY-TEST-APP.md](DEPLOY-TEST-APP.md) §4).

| Protection | test | prod |
| --- | --- | --- |
| Deployment branch policy | `deploy/test` (state branch, ADR-0018), `main`, `vibe/**` | `deploy/prod` (state branch, ADR-0018) |
| Required reviewers | — | `merlin-pinpin` (approval before any prod job consumes prod secrets) |
| Wait timer | — | — |
| Actions policy (who may trigger the workflow) | `deploy-test-dispatch`: `kingdoms-deployer[bot]` + admins (via REST API — the UI picker does not list third-party apps); events `workflow_dispatch`, `push` | — (prod deploys are state-branch pushes written by the release pipeline only; the `prod` environment reviewers gate the Deploy environment run) |

Reading the matrix:

- **test** is open to feature branches (`vibe/**`) so the game designer can
  validate a PR live in Discord via `/deploy` before it merges. The
  dispatch always references `ref: main` on this repository, so the
  `vibe/**` branch-policy entry is tolerance, not the actual gate — the
  real gates are the Actions policy (who dispatches) and the
  `BOTFORGE_IMAGE` input (what image runs).
- **prod** deploys only from `main` (a released image, per ADR-0007) and
  requires an explicit human approval before the job starts. Even an
  accidental `workflow_dispatch` of `deploy.yml` cannot consume prod
  secrets without a reviewer's approval.

## Deploying a test image from a services branch

The flow for validating code changes on the test environment (no manual
branch on this repository):

1. The code change lives on a `vibe/<slug>` branch of **botforge-services**,
   opened as a PR (draft while work remains).
2. The **Docker** workflow of botforge-services builds the image on
   every PR push; `/deploy` publishes a timestamped tag
   (`pr-<id>-<timestamp>-<sha>`) from the PR head.
3. A `/deploy` comment on the PR builds/publishes that exact image and
   dispatches this repository's **Pin state** workflow with it via the
   `kingdoms-deployer` GitHub App (ephemeral token, Actions: write only).
4. The pinned state push triggers the deploy chain on the self-hosted
   runner (test VPS); it pulls the
   authenticated image (package access: botforge-infra has role Read on the
   package — [DEPLOY-TEST-APP.md](DEPLOY-TEST-APP.md) §5), and restarts the
   bot with it. The health gate confirms the stack is healthy.

So: the image under test is always a PR image tagged by PR number,
timestamp and commit SHA — never an untagged `latest`, never a hand-built
local image on the VPS. Rolling back is re-running `/deploy` on the
previous PR, or letting the next config-change deploy on `main` restore the
default image (`sha-<sha>` of main).

The `/deploy` dispatch also carries the **deploy URL** and the
**version label** so the bot's `/status` shows what is running
(botforge-infra#37): a PR deploy's URL is the permalink of the deployment
comment (label `pr-<id>-<timestamp>-<sha>`), a config-change deploy on

`main` points at the deployed source tree `/tree/<sha>` (label
`main@<sha>`), and a prod deploy points at the released `vX.Y.Z` GitHub
release (label `vX.Y.Z`).

The Deploy field additionally links the botforge-infra deploy job itself
(`BOTFORGE_DEPLOY_RUN_URL`).

## Seeding at deploy time

The deploy workflows accept an optional post-deploy seed (the same
idempotent CLIs as `/seed`), so an environment can be deployed **and**
loaded in one validated run:

- `seed_type` — `users` (the known-users import, allowed on every
  environment including prod) or `ladder-season` (the full ladder
  season seed, test environments only);
- `seed_guild_id` — the target test guild (`ladder-season` only); it
  must equal the environment's `TEST_GUILD_ID` or the seed aborts
  before any write;
- `seed_confirm` — the explicit validation: type exactly `SEED <env>`
  (e.g. `SEED merlin`); anything else aborts the seed.

The pre-seed scan step writes the destructive-run warning to the run
summary before any write: the users import is **last-import-wins**
(a profile linked to another account is rebound), and a changed
ladder-season dataset replays the guild's matches, rating history and
season enrollments.

Prod stays minimal by design: only the `users` seed is accepted there —
the known users and the CF ladder on its guild; `ladder-season` on prod
fails closed before touching data.
