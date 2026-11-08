# Contributing to BotForge (botforge-infra)

This repository holds the infrastructure: Docker Compose environments,
CI/CD workflows, GitOps state branches and the deployment scripts run on
the VPS. You do not need an AI agent to contribute: everything below runs
with a public clone and no credentials.

## Prerequisites

- `git`, `bash`
- Docker + Docker Compose (manifest validation, local stack)
- `shellcheck` (script linting; install it via your package manager)
- Python 3.12+ and a clone of
  [`botforge-services`](https://github.com/jj-guild/botforge-services)
  are **not** needed here — infra checks are self-contained.

## Set up

```bash
git clone https://github.com/jj-guild/botforge-infra.git
cd botforge-infra
```

There is no build step: this repository is manifests, workflows and
shell scripts. The [Makefile](Makefile) wraps the checks
(`make check`) and the deploy diagnostics (`make doctor`,
`make diagnose-deploy-<env>`) — `make check` fails closed when a tool is
missing, never a green-ish skip.

## Your first contribution

1. **Pick or create an issue** (from a
   [template](https://github.com/jj-guild/botforge-infra/issues/new/choose) —
   blank issues are disabled; non-compliant ones are flagged `invalid`).
2. **Create a branch** from `main`:

   ```bash
   git checkout -b fix/my-change main
   ```

3. **Make your change** ([docs/DEVELOPER.md](docs/DEVELOPER.md):
   environments are data, one directory under `envs/` each; deployment is
   GitOps-driven, never applied by hand on the VPS).
4. **Run the local checks before pushing** — the same ones CI runs, via
   the Makefile:

   ```bash
   make check
   ```

   That runs `bash -n` on every script, shellcheck (same severity as CI,
   fails closed when shellcheck is missing) and the compose manifest
   validation. The manifest validation needs the two required variables
   (use placeholders locally, exactly like CI does):

   ```bash
   DISCORD_TOKEN=ci-placeholder \
   BOTFORGE_IMAGE=ghcr.io/jj-guild/botforge-services:sha-ci \
     docker compose -f envs/test/docker-compose.yml config --quiet
   ```

   Also check the fail-closed behavior: without `DISCORD_TOKEN`, every
   `envs/*/docker-compose.yml` must fail `docker compose config` — CI
   enforces it on every PR.

5. **Open a pull request.** Conventional Commit title (`fix:`, `feat:`,
   `chore:`, `docs:`), small focused diff, description linking the issue
   with a closing keyword (`Closes #N`).
6. **Wait for review**; the maintainer merges.

## Where things live

| Path | Content |
| ---- | ------- |
| `envs/<env>/` | One directory per environment: `docker-compose.yml` + `state/` (the pinned state files synced to the `deploy/<env>` branches) |
| `deploy/<env>` | Protected state branches (GitOps source of truth, ADR-0018) — not regular files on `main` |
| `.github/workflows/` | CI checks + the deploy chain: `deploy.yml` (routing), `deploy-env.yml` (per-env deploy), `pin-state.yml` (image pins), `sync-state.yml` (main → state branches) |
| `scripts/` | `deploy.sh` (idempotent, health-gated), `rollback.sh`, `backup_db.sh`, `restore_db.sh` |
| `docs/` | ENVIRONMENTS.md, GITOPS.md, DEPLOYMENT.md, VPS-SETUP.md |

## Rules

- Everything in **English** (scripts, comments, docs, commits, PRs).
- Deploy scripts stay idempotent, fail-closed and rollback-capable.
- Never handle secret values: real credentials live only in GitHub
  environment secrets (entered by ops in the web UI).
- Every infrastructure change is reflected in the `botforge`
  documentation (source of truth) before merge.
- A required status check never uses a `paths:` filter (it must report
  on every PR or it silently blocks merges).

## The vibe-coding model

This project is primarily built through an AI-agent workflow
([operating model](https://github.com/jj-guild/botforge/blob/main/docs/VIBEWORKFLOW.md));
agent sessions run the same checks you just ran. Human contributions are
welcome and follow exactly the path above — no agent required.

## CLA process

- First-time contributors must accept the CLA before their PR can be
  merged.
- Comment `/cla` on your PR or follow the CLA workflow.
- A CLA check runs on every PR from external contributors.

## License

By contributing, you agree that your contributions will be licensed under
the [AGPL-3.0](LICENSE) (see [CLA.md](CLA.md) for the full grant,
including the project's relicensing option).
