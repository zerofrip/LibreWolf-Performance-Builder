# Phase 2 evidence log

## GHA run 33754159563 (FAILED — not disk)

**CONFIRMED**

- Baseline validation job: PASS
- LibreWolf `155.0-1` / Firefox `155.0`
- Pinned bsys6 at failure: `1ca738899aeece8aad2f2811cbb00b707786ee33` (GitLab mirror)
- Generated mozconfig target: `--target=x86_64-pc-mingw32`
- Firefox configure error: `Target x86_64-pc-mingw32 is no longer supported, try x86_64-pc-windows-gnu or x86_64-pc-windows-msvc instead`
- Disk: initial ~74 GB free → ~73 GB after source fetch → ~68 GB after failure/extraction — **not** an ENOSPC failure

Authority for the reject: Firefox `build/moz.configure/init.configure` `check_mingw_triplet` (Firefox 155 / `FIREFOX_155_0_RELEASE`).

## Upstream fix (preferred path)

**CONFIRMED**

- Codeberg `librewolf/bsys6` commit `0ed119d2f821d1472cadeef6dd9bc5f7ae64c187` (`Use windows-msvc everywhere for x86_64`) changes:

```text
MOZ_TARGET=$ARCH-pc-mingw32  →  $ARCH-pc-windows-msvc
```

- Tag `155.0-1` = `24c40ffaa25b558e4c5ce9f326bc4466ba7608bc` includes that migration
- Official Windows cross toolchain / Rust targets already use `*-pc-windows-msvc` (`Dockerfile.windows`, historical `prepare.sh`)
- GitLab `master` at `1ca7388` was **stale** relative to Codeberg and still emitted `mingw32`

**Overlay action:** update `upstream/bsys6.rev` to Codeberg tag `155.0-1` (`24c40ff…`). No local target-triple patch.

## Remaining UNKNOWN until rerun

- Whether GitHub-hosted baseline completes end-to-end after the pin update
- Peak disk / LLVM / Rust versions from a successful container build
- Final package name / size / SHA-256

## GHA run 33756336955 (FAILED — new blocker after triple fix)

**CONFIRMED:** `local-validate` PASS with `MOZ_TARGET=x86_64-pc-windows-msvc` (bsys6 `24c40ff`).

**CONFIRMED:** configure accepted `--target=x86_64-pc-windows-msvc` / `checking for target system type... x86_64-pc-windows-msvc` (mingw32 reject gone).

**CONFIRMED:** build then failed with `ERROR: Cannot find a Windows SDK for version >= 0x0603`.

**CONFIRMED:** configure used `WINSYSROOT=/github/home/.mozbuild/win-cross/vs` because GHA container sets `HOME=/github/home`, while `Dockerfile.windows` installs the SDK at `/root/.mozbuild/win-cross/vs`.

**CONFIRMED:** still not a disk failure (avail ~75G → ~68G).

**Fix applied:** set `HOME=/root`, `MOZBUILD=/root/.mozbuild` for the build job (and mirror in `build-windows-baseline.sh` when the image SDK exists).

## GHA run 33757327905 (FAILED — runner lost communication)

**CONFIRMED (annotation):**

> The hosted runner lost communication with the server. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error.

| Field | Value |
|-------|-------|
| Job start | 2026-09-03T12:50:13Z |
| Job end | 2026-09-03T13:53:29Z (~63m) |
| Build step start | 2026-09-03T12:54:07Z |
| Build step end | never completed (`completed_at: null`, stayed `in_progress`) |
| Build logs | Azure `BlobNotFound` — not retrievable |
| Build artifacts | none (upload step never ran) |

**CONFIRMED:** `local-validate` PASS.

**CONFIRMED:** previous mingw32 configure failure is **not** this failure mode (job lasted ~1h into build).

**INFERRED:** `x86_64-pc-windows-msvc` + WinSDK path were OK enough to pass configure (contrast run 33756336955 SDK death at ~1.5m).

**INFERRED root cause:** GitHub-hosted runner resource starvation (memory/CPU) during compile killed/disconnected the agent.

**DISK:** unknown as sole cause; GitHub message points primarily at CPU/Memory.

**Minimal repair for next run:** `MOZ_MAKE_FLAGS=-j2`, optional swap, toolchain probe, stdout/file heartbeats, tee mach logs, split `bsys6 source` then inject parallelism into mozconfig before `build package`.

## GHA run 33854319687 (FAILED — gkrust rustc SIGKILL)

| Field | Value |
|-------|-------|
| Commit | `705247bea17c34b645e9ccba5b544d4a91ac21b9` |
| Duration | ~2105 s (~35 min) to failure |
| Disk at failure | ~62 GiB free (`heartbeat` / `gha-after`) — **NOT blocker** |
| Swap | Attempted 8G; **unavailable** in container |
| First fail | `could not compile gkrust (lib)` — rustc `(signal: 9, SIGKILL: kill)` |
| rustc flags | `-Clto` … `-C codegen-units=1` (full gkrust crate LTO) |
| Configure PGO | `--enable-profile-use` + `--with-pgo-profile-path=.../assets/windows.profdata` |
| Configure C/C++ LTO | **absent** (no `--enable-lto`) |
| Metadata bug | claimed `"lto": false` while Rust LTO was active — semantics fixed to overlay vs upstream layers |

**CONFIRMED**

- Target triple `x86_64-pc-windows-msvc` PASS
- MOZBUILD/SDK / clang 21.1.8 / rustc 1.97.1 PASS
- Configure complete; deep C/C++ + Rust compile progressed
- Upstream PGO profile-use **ACTIVE**
- Upstream bsys6 `--enable-lto` **INACTIVE**
- Upstream Firefox `gkrust` Rust LTO **ACTIVE** (expected via `rust.mk`, not overlay)

**OOM status (at time of this run): STRONGLY SUSPECTED** — later **CONFIRMED** on instrumented run `33862245103` (see below). This run lacked cgroup `oom_kill` capture.

### Phase decision gate (33854319687) — superseded

```text
RUN: 33854319687
...
OOM: STRONGLY SUSPECTED  →  superseded by CONFIRMED on 33862245103
GITHUB-HOSTED BASELINE FEASIBILITY: UNLIKELY → INSUFFICIENT (confirmed later)
PHASE 2: BLOCKED
```

## Infrastructure recovery (2026-09-04)

**CONFIRMED direction:** do not weaken upstream PGO / Firefox `gkrust -Clto`; add runner abstraction + memory evidence instead.

| Piece | Location |
|-------|----------|
| Memory samples + summary | `scripts/memory-report.sh` → `artifacts/disk/memory-samples.jsonl`, `artifacts/memory-summary.json` |
| Proven optimization layers | `scripts/detect-optimization-state.sh` |
| Reusable build job | `.github/workflows/baseline-windows-reusable.yml` |
| Standard / selectable runners | `.github/workflows/baseline-windows.yml` (`runner_profile`) |
| Self-hosted manual wrapper | `.github/workflows/baseline-windows-self-hosted.yml` + `docs/SELF-HOSTED.md` |

Public-repo GitHub docs list `ubuntu-latest` as **4 CPU / 16 GB**; authoritative job limit remains cgroup `memory_limit_bytes` when non-null.

## GHA run 33862245103 (FAILED — OOM CONFIRMED)

| Field | Value |
|-------|-------|
| Commit | `5ca1290` |
| Duration | ~2334 s |
| Result | `gkrust` rustc SIGKILL during `-Clto` / `codegen-units=1` |
| MemTotal | **16,377,684 kB (~15.62 GiB)** |
| SwapTotal | **3,145,724 kB (~3.0 GiB)** |
| cgroup | v2; `memory.max=max`, `memory.high=max` |
| memory.peak | **15,628,947,456 bytes (~14.56 GiB)** |
| Near failure | SwapFree ≈ 2 MiB; `oom_kill` flipped 0 → **1** |
| cgroup `oom` | 0 |
| cgroup `oom_kill` | **1** |
| Disk | NOT BLOCKER |
| Upstream PGO | proven `true` |
| Upstream Rust LTO | proven `true` |
| Overlay opts | all false |

**OOM = CONFIRMED** (direct cgroup evidence, not SIGKILL alone).

**STANDARD GITHUB-HOSTED BASELINE FEASIBILITY = INSUFFICIENT** for the current upstream-equivalent Windows build. Do not weaken upstream PGO / Rust LTO / `windows.profdata` / codegen-units to greenwash CI. Do not retry standard full builds except explicit diagnostics (`UNDERSTAND-OOM`).

## GHA run 33895224558 (SUCCESS — Phase 2 self-hosted)

| Field | Value |
|-------|-------|
| Commit | `61d3c2c` |
| Runner | `librewolf-builder-wsl` (labels: self-hosted, Linux, X64, librewolf-builder) |
| Host MemTotal | 32,646,784 kB (~31.13 GiB) |
| Host SwapTotal | 8,388,608 kB (~8.0 GiB) |
| Duration | 9610 s (~2 h 40 m) |
| Target | `x86_64-pc-windows-msvc` |
| Artifact | `librewolf-155.0-1-windows-x86_64-package.zip` |
| Size | 158,771,036 bytes (~151.4 MiB) |
| SHA-256 | `455886377761ae45f4bcc250021ce9a20858eb1811d3a99936e4bf076829c054` |
| Package check | zip OK; contains `librewolf/librewolf.exe`, `xul.dll`, 53 entries |
| memory.peak | 30,488,612,864 bytes (~28.39 GiB) |
| Peak swap used | ~2,100,432 kB (~2.00 GiB) from samples (`SwapTotal−SwapFree` max) |
| oom / oom_kill | **0 / 0** (did not increase) |
| clang | 21.1.8 (taskcluster) |
| rustc | 1.97.1 |
| LibreWolf / Firefox | 155.0-1 / 155.0 |
| bsys6 | `24c40ffaa25b558e4c5ce9f326bc4466ba7608bc` |
| source | `03ba053934d5f6c7a11cb472424017caafd607e9` |
| Upstream PGO | **true** (`--enable-profile-use` in configure/mozconfig) |
| Upstream C/C++ LTO | **false** (no `--enable-lto`) |
| Upstream Rust gkrust LTO | **active** (Firefox `rust.mk` default; `Compiling gkrust` succeeded; prior OOM run showed rustc `-Clto`) |
| Overlay opts | all false |

```text
PHASE 2: PASS
PHASE 3: BLOCKED — awaiting human authorization
```

Measured on this one successful self-hosted run (~31 GiB RAM host). Do **not** treat 32 GiB / 64 GiB as a universal hard requirement from a single data point.







