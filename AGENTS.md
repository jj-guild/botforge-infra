# AGENTS.md

`botforge-infra` — Docker, CI/CD, GitOps manifests and deployment scripts
for the BotForge Discord bot platform.

## Read first

- [botforge/docs/CONVENTIONS.md](https://github.com/jj-guild/botforge/blob/main/docs/CONVENTIONS.md)
  — conventions shared by the three repositories (language,
  humans-never-code, secrets, PR lifecycle, issues, checks).
- [botforge/docs/VIBEWORKFLOW.md](https://github.com/jj-guild/botforge/blob/main/docs/VIBEWORKFLOW.md)
  — operating model (roles, session loop, approvals).
- [docs/DEVELOPER.md](docs/DEVELOPER.md) — this repo's layout, environment
  model, checks, deploy chain, workflow pitfalls.

## Repositories

- `botforge` (documentation, source of truth)
- `botforge-services`: core, Discord platform, mods, YAML configs
- `botforge-infra` (this repo): Docker, CI/CD, GitOps, deploy scripts

## Local rules

- Deployment is **GitOps-driven**: state branches are applied by CI/CD,
  never by hand on the hosting; deploy scripts stay idempotent with rollback.
- Ops manage environments and secrets in the GitHub web UI only; the agent
  never handles secret values.
- Verify scripts with `bash -n` and shellcheck (if available) before
  pushing; sandbox-limited checks are covered by CI workflows.
- **Never rename a workflow or a workflow job backing a required status
  check** — GitHub matches check contexts by exact name, so a rename
  silently blocks merges (see DEVELOPER.md, *Workflow pitfalls*).
- Any infrastructure change is reflected in the `botforge` docs (source
  of truth) before merge.
- **Enrich the docs and skills proactively** (developer-mandated): when
  the session's work teaches a rule, pitfall or pattern, update the
  matching skill page, convention or AGENTS.md entry as part of the
  change — see the botforge CONVENTIONS.md
  (*Documentation is part of the change*).
- Issue templates: `## Objective` / `## Context` / `## Specifications` /
  `## Acceptance criteria` / `## Dependencies` (blank issues disabled).
- **Issue references** are GitHub autolinks: same-repo `#N`, cross-repo
  `owner/repo#N` (e.g. `jj-guild/botforge-services#52`) — a bare
  `repo#N` renders as plain text; never write it. See CONVENTIONS.md,
  *Documentation is part of the change*.
- **Automation mandate:** no one-off commands, for humans or sessions —
  every recurring operation is a committed Makefile target, script or
  workflow, and a useful improvised command is committed ("learned").
  Humans on GitHub only merge PRs and approve prod deploys
  (+ one-time bootstrapping) — see the botforge
  [Automate or learn](https://github.com/jj-guild/botforge/blob/main/.agents/skills/automate-or-learn/SKILL.md)
  skill and CONVENTIONS.md (*Human GitHub scope*, *Everything is
  automation*).
- **PR merges, cowboy mode, branch cleanup and user-branch rules are
  defined once in the botforge CONVENTIONS.md** (single source of
  truth, all three repos): see
  [botforge/docs/CONVENTIONS.md](https://github.com/jj-guild/botforge/blob/main/docs/CONVENTIONS.md)
  — *Cowboy mode* (API-blocked merges, maintainer-only direct pushes
  with per-push confirmation, never force-push `main`) and
  *Integration branches* (never delete `vibe/<alias>/main`).