# Runner disk maintenance

Every environment runner is a self-hosted GitHub Actions runner on a
VPS, colocated with its Docker daemon. Deployments accumulate drift on
the host disk: each `/deploy` publishes a fresh image tag (~300 MB),
build cache grows, and the runner writes diagnostic logs. Nothing
reclaimed that drift automatically — until the 2026-10-10 drasah
incident, where a full disk crashed MongoDB mid-write and wedged the
deploy health gate (a zombie container that `docker compose up -d`
never restarts because nothing changed).

The `Environment maintenance` workflow
(`.github/workflows/env-maintenance.yml`) now runs on every
environment runner:

- **weekly** — Sundays 05:10 UTC, all environments (matrix);
- **on demand** — `workflow_dispatch` with an environment choice.

It is non-destructive by construction:

- `docker image prune -af` removes **only images used by no container**
  — running or stopped stacks keep theirs; volumes are never touched;
- `docker builder prune -af` removes the build cache only;
- runner `_diag` diagnostic logs older than **7 days** are deleted.

After the reclaim, a disk still above **85%** opens a tracking issue —
the threshold leaves time to act before the disk fills and kills a
service again.

## Operational rules

- Never run a maintenance dispatch while a deploy is in flight on the
  same environment (image prune vs. pull). The job-level concurrency
  group serializes maintenance runs only — deploy runs are not part of
  it, hence the quiet weekly slot.
- A container killed by a full disk can survive as a zombie: Docker
  reports it `running` while the process is dead. `docker compose up -d`
  will NOT restart it (no config change). The fix is
  `docker compose restart` (or the `/restart <env>` ops command on a
  kingdoms-services PR), never a redeploy.
- A workflow that hangs on a wedged runner should always set
  `timeout-minutes`: without it a stuck self-hosted job holds its slot
  for the 6-hour default and cannot be cancelled except via the UI (the
  dead worker never acknowledges the cancel API call).
