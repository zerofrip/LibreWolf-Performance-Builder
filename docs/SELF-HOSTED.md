# Self-hosted runner for Phase 2 Windows baseline

This repository can run the **same** Phase 2 build job on a self-hosted host.
Only the runner selector changes; pins, container image, scripts, mozconfig
handling, metadata, and artifacts stay identical via
`.github/workflows/baseline-windows-reusable.yml`.

## Status

| Item | Status |
|------|--------|
| Reusable full-build workflow | Ready |
| Manual self-hosted wrapper | Ready (`baseline-windows-self-hosted.yml`) |
| Registered runner with required labels | **Proven** — `librewolf-builder-wsl` completed Phase 2 run `33895224558` |
| Standard GitHub-hosted full build | **Insufficient** (OOM CONFIRMED, run `33862245103`) — not used on push |

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
Sufficient RAM (see measured Phase 2 profile + planning tiers below)
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

| Workflow | Trigger | What runs |
|----------|---------|-----------|
| `baseline-windows.yml` | push/PR | **local-validate only** (no full browser build) |
| `baseline-windows.yml` | `workflow_dispatch` + `run_full_build` | full build on selected profile (default **self-hosted**) |
| `baseline-windows-self-hosted.yml` | manual; type `READY` | full build on self-hosted labels |

Do **not** start the self-hosted workflow until a compatible runner is online.

Standard full build on `ubuntu-latest` requires typing `UNDERSTAND-OOM` — it is
diagnostics-only after OOM confirmation on run `33862245103`.

## Resource guidance (measured Phase 2 + planning)

Measured on standard public GHA (run `33862245103`):

```text
MemTotal     ≈ 15.62 GiB
SwapTotal    ≈ 3.0 GiB
memory.peak  ≈ 14.56 GiB
oom_kill     = 1 during gkrust -Clto
```

Therefore standard ~16 GiB is **insufficient**.

**Measured** on successful self-hosted Phase 2 run `33895224558` (`librewolf-builder-wsl`):

```text
MemTotal     ≈ 31.13 GiB
SwapTotal    ≈ 8.0 GiB
memory.peak  ≈ 28.39 GiB
peak swap    ≈ 2.00 GiB used
oom_kill     = 0
```

This is one successful profile — **not** a universal minimum. Planning tiers:

```text
~31 GiB RAM + 8 GiB swap:  proven sufficient for this Phase 2 baseline once
64 GiB RAM:                preferred headroom for Phase 2 retries / future PGO/CSIR
128 GiB+:                  future Full C/C++ LTO experiments only; not required for current Phase 2
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
supports it — not from SIGKILL alone. Run `33862245103` met that bar (`oom_kill=1`).

## Larger GitHub-hosted runners (optional)

Not required. If an organization provides larger runners (Team/Enterprise),
use `workflow_dispatch` → `runner_profile=larger-custom` and set
`larger_runner_label` to the org-defined label.

Personal public repositories often **cannot** access larger runners.
Do not assume availability for this repo.


