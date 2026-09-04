# Self-hosted runner for Phase 2 Windows baseline

This repository can run the **same** Phase 2 build job on a self-hosted host.
Only the runner selector changes; pins, container image, scripts, mozconfig
handling, metadata, and artifacts stay identical via
`.github/workflows/baseline-windows-reusable.yml`.

## Labels

Register the GitHub Actions runner with **all** of:

```text
self-hosted
linux
x64
librewolf-builder
```

Do **not** hard-code a machine hostname in workflows.

## Host prerequisites

```text
Linux x86_64
Docker (required — the job uses container: codeberg.org/librewolf/bsys6:windows)
GitHub Actions runner application
Sufficient RAM (see tiers below — hypotheses until measured)
Sufficient disk (tens of GB free for objdir + source; prefer ≥100 GB free)
Network access to:
  - github.com / api.github.com / Actions endpoints
  - codeberg.org (bsys6 image / git)
  - librewolf.dev (source tarball packages)
```

Because the build runs **inside** the LibreWolf bsys6 Windows container, do **not**
install Firefox build dependencies on the host unless the runner itself needs them.

The runner user must be able to run Docker containers (often via `docker` group).

## Workflows

| Workflow | Trigger | Runner |
|----------|---------|--------|
| `baseline-windows.yml` | push/PR | always `ubuntu-latest` (standard) |
| `baseline-windows.yml` | `workflow_dispatch` + `runner_profile=self-hosted` | self-hosted labels |
| `baseline-windows-self-hosted.yml` | manual only; requires typing `READY` | self-hosted labels |

Do **not** start the self-hosted workflow until a compatible runner is online.

## Recommended resource tiers (planning guidance — not hard requirements)

These are hypotheses until cgroup `memory.peak` / build success prove otherwise:

```text
16 GB:  likely marginal for gkrust Rust LTO
32 GB:  first realistic trial
64 GB:  preferred for future PGO/CSIR work
128 GB+: relevant if future Full C/C++ LTO experiments are attempted
```

LibreWolf historically needed >128 GB for Windows **Full C/C++** LTO link
(bsys6 commit `36f8c3df`). That is separate from Firefox’s default `gkrust -Clto`.

## Authoritative memory evidence

Always prefer runtime measurements over documentation claims:

```text
artifacts/memory-summary.json
artifacts/disk/memory-samples.jsonl
artifacts/disk/memory-before.txt / memory-after.txt
```

Classify OOM as **CONFIRMED** only when cgroup `oom` / `oom_kill` (or equivalent)
or kernel OOM evidence supports it — not from SIGKILL alone.

## Larger GitHub-hosted runners (optional)

Not required. If an organization provides larger runners (Team/Enterprise),
use `workflow_dispatch` → `runner_profile=larger-custom` and set
`larger_runner_label` to the org-defined label.

Personal public repositories often **cannot** access larger runners.
Do not assume availability for this repo.
