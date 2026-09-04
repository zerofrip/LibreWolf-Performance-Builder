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

**OOM status: STRONGLY SUSPECTED (not CONFIRMED)**

- SIGKILL during multi-minute `gkrust` LTO on GHA-hosted runner is consistent with memory killer / cgroup OOM
- Disk exhaustion disproved
- This run did **not** capture readable cgroup `oom_kill` / kernel OOM lines (heartbeat lacked MemAvailable; `free` may be missing in image)
- Next runs add `scripts/memory-report.sh` (meminfo, ulimit, cgroup v1/v2 `memory.current|peak|events`, best-effort dmesg)

**Do not** disable upstream PGO or Rust gkrust LTO to greenwash GHA without explicit authorization.

### Phase decision gate (33854319687)

```text
RUN: 33854319687
TARGET TRIPLE: PASS
MOZBUILD: PASS
CONFIGURE: PASS
C/C++ COMPILE: PASS to observed point
RUST COMPILE: PASS until gkrust final staticlib/LTO
FIRST FAILING COMPONENT: gkrust
FAILURE: rustc SIGKILL during -Clto, codegen-units=1
DISK: NOT BLOCKER
OOM: STRONGLY SUSPECTED
UPSTREAM PGO: ACTIVE
UPSTREAM RUST LTO: ACTIVE
GITHUB-HOSTED BASELINE FEASIBILITY: UNLIKELY (pending authoritative cgroup evidence on a fresh instrumented run)
RECOMMENDED INFRASTRUCTURE: collect cgroup memory.max/peak/oom_kill on standard public GHA (docs: 4CPU/16GB host VM); then self-hosted high-RAM (epsilon-class) or optional larger runners; keep upstream PGO + rust.mk LTO
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
| Commit | `5ca1290` (docs + memory infra + reusable runner) |
| Duration | ~2334 s |
| Result | `gkrust` rustc SIGKILL during `-Clto` |
| MemTotal (visible) | 16377684 kB (~15.62 GiB) |
| cgroup `memory.max` | `max` → summary `memory_limit_bytes: null` (no lower cgroup cap) |
| cgroup `memory.peak` | 15628947456 (~14.56 GiB) |
| cgroup `oom` | 0 |
| cgroup `oom_kill` | **1** (was 0 at start) |
| Upstream PGO | proven `true` (mozconfig) |
| Upstream Rust LTO | proven `true` (build-log `-Clto`) |
| Overlay opts | all false |

**OOM: CONFIRMED** via cgroup v2 `memory.events` `oom_kill=1` coincident with `gkrust` SIGKILL and peak RSS near host MemTotal. Kernel dmesg unreadable (`Operation not permitted`).

Do **not** repeatedly retry standard GHA for this baseline after this confirmation.

```text
STANDARD GHA:
memory.max: max (null limit below host)
memory.peak: 15628947456 (~14.56 GiB)
oom: 0
oom_kill: 1
result: FAILURE (gkrust SIGKILL)

SELF-HOSTED WORKFLOW:
READY (workflow) / NOT READY (no registered runners)

LARGER RUNNER:
OPTIONAL / UNKNOWN for this personal public repo

PHASE 2:
BLOCKED ON INFRASTRUCTURE
```





