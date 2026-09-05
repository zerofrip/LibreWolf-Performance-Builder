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

Authoritative close-out run. Workflow: **Baseline Windows (self-hosted manual)** / `workflow_dispatch` / commit `61d3c2c8842fba330d60eaed898148b5b93f70e9` / conclusion **SUCCESS**.

### Artifact inventory (do not confuse layers)

| Kind | Path / name | Notes |
|------|-------------|-------|
| GitHub Actions artifact | `baseline-windows-x64-self-hosted` | API `size_in_bytes` **158,567,603** (~151.2 MiB) — wrapper archive, **not** the browser package |
| Actual browser package | `out/librewolf-155.0-1-windows-x86_64-package.zip` | **158,771,036** bytes |
| Package checksum file | `out/librewolf-155.0-1-windows-x86_64-package.zip.sha256` | matches package |
| Metadata | `artifacts/baseline-windows-metadata.json` | pins, toolchain, hashes |
| Memory evidence | `artifacts/memory-summary.json`, `artifacts/disk/memory-*.txt`, `memory-samples.jsonl` | cgroup + /proc |
| Build logs | `artifacts/logs/bsys6-build-package.log`, `bsys6-source.log`, `mozconfig-resource.txt` | configure + mach |
| Toolchain / target | `artifacts/toolchain-probe.txt`, `generated-target.txt` | clang/rustc/cargo |
| Local-validate sidecar | artifact `baseline-local-validate-self-hosted` | same run; job PASS |

### Browser package proof

| Field | Value |
|-------|-------|
| filename | `librewolf-155.0-1-windows-x86_64-package.zip` |
| format | Zip (deflate); `unzip -t` → **No errors** |
| byte size | **158,771,036** |
| SHA-256 | `455886377761ae45f4bcc250021ce9a20858eb1811d3a99936e4bf076829c054` |
| structure | top-level `librewolf/`; **53** entries; uncompressed total listed **486,405,230** |
| payload | `librewolf/librewolf.exe` (MZ PE), `xul.dll`, `omni.ja`, `browser/omni.ja`, `plugin-container.exe` |

Packaging log: bsys6 moved `librewolf-155.0-1.en-US.win64.zip` → package path; printed matching SHA-256.

### Target / toolchain (from configure + probe — not from filenames)

| Field | Evidence |
|-------|----------|
| target triple | configure: `--target=x86_64-pc-windows-msvc`; `checking for target system type... x86_64-pc-windows-msvc`; rust target triplet same; `generated-target.txt` |
| clang | 21.1.8 (taskcluster-F58RnQSfSg68MZGEByyGQg) |
| rustc | 1.97.1 (8bab26f4f 2026-07-14) |
| cargo | 1.97.1 (c980f4866 2026-06-30) |
| Windows SDK | configure: `0x0a00` in `.../Windows Kits/10`; Universal CRT **10.0.26100.0** |

### Optimization semantics (proven — not copied)

| Key | Value | Evidence |
|-----|-------|----------|
| overlay_lto | **false** | empty baseline frag; no overlay LTO env; mozconfig-resource has only CI `-j2` + target |
| overlay_pgo | **false** | no overlay PGO env / fragments |
| upstream_cpp_lto | **false** | configure options list has **no** `--enable-lto` |
| upstream_rust_lto | **true** | see proof chain below |
| upstream_pgo | **true** | `--enable-profile-use` + `--with-pgo-profile-path=.../assets/windows.profdata` |
| x86_64_v3 | **false** | no v3 flags in configure / mozconfig-resource |
| csir | **false** | no CSIR flags |

Upstream PGO profile path basename: **`windows.profdata`**.

**Rust LTO / codegen-units proof chain (this run’s cargo log does not echo rustc cmdline on success):**

1. Built source tarball SHA-256 `5d951d8071ef6bcc4eab8bba1492e269af728c83586437ec2a7db11d46be36f6` (metadata) matches pinned tarball.
2. That tree’s `config/makefiles/rust.mk`: release staticlib (not gkrust_gtest, not `MOZ_LTO_RUST_CROSS`) adds `cargo_rustc_flags += -Clto`; without `DEVELOPER_OPTIONS`, `RUSTFLAGS += -C codegen-units=1`.
3. This configure had **no** `--enable-lto` → no cross-language Rust LTO path that would disable the default `-Clto` block.
4. Log: `Compiling gkrust` @ 63:09.72 → `Finished release profile [optimized] target(s) in 64m 10s` @ 72:43.44 (**PASS**).
5. Corroboration (same upstream-equivalent pipeline): run `33862245103` rustc line showed `-Clto` … `-C codegen-units=1` before OOM.

Detector note: uploaded `baseline-windows-metadata.json` still has `"upstream_rust_lto": false` / `evidence.upstream_rust_lto: null` because `detect-optimization-state.sh` only sets true when the build log contains a literal `-Clto` rustc line. That is a **detector gap on success logs**, not proof that Rust LTO was off. Authoritative semantics for close-out: **true** via rust.mk + successful gkrust release finish (+ prior run cmdline).

### Former gkrust blocker

| Item | Result |
|------|--------|
| gkrust | **PASS** (Finished release, 64m 10s) |
| Rust LTO | **PASS** (semantics active; crate completed — contrast standard-hosted `33862245103` OOM at same stage) |

### Memory evidence (begin → end)

| Metric | Value |
|--------|-------|
| MemTotal | 32,646,784 kB (~31.13 GiB) |
| SwapTotal | 8,388,608 kB (~8.0 GiB) |
| memory.max | `max` (unlimited in cgroup) |
| memory.peak | **30,488,612,864** bytes (~28.39 GiB) |
| peak swap use | **~2,150,842,368** bytes (~2.00 GiB) max(`SwapTotal−SwapFree`) in `memory-samples.jsonl` |
| swap.peak (cgroup) | **null** / not exposed as a usable peak field |
| oom / oom_kill begin | **0 / 0** |
| oom / oom_kill end | **0 / 0** (unchanged; no OOM kill) |
| peak RAM / physical RAM | ~0.912 |

### Runner characteristics

| Field | Value |
|-------|-------|
| name | `librewolf-builder-wsl` |
| labels | `self-hosted`, `linux`, `x64`, `librewolf-builder` (job API) |
| OS | Linux (container build; host_os metadata Linux) |
| architecture | x86_64 |
| CPU count | **UNKNOWN** in run artifacts (not recorded); do not invent |
| RAM | MemTotal 32,646,784 kB |
| swap | SwapTotal 8,388,608 kB |
| free disk before build | ~**366G** avail on `/__w` (`before-build.txt`) |

### Phase 2 success chain (close-out)

```text
local validation              PASS  (job local-validate + artifact)
self-hosted preflight         PASS  (runner online; required labels)
target triple                 PASS  (configure x86_64-pc-windows-msvc)
configure                     PASS
C/C++ build                   PASS  (build continued past C++ into gkrust + finish)
gkrust final Rust LTO         PASS
remaining build               PASS  (Finished packaging locales; overall SUCCESS)
packaging                     PASS  (bsys6 package.zip + SHA printed)
real Windows x64 package      PASS  (PE + structure)
artifact upload               PASS  (baseline-windows-x64-self-hosted)
package SHA256                RECORDED
baseline semantics            PASS  (table above)
memory evidence               RECORDED
OOM kill during build         NO
```

Contrast (historical — retain):

```text
standard GitHub-hosted (33862245103): OOM CONFIRMED
self-hosted (33895224558):            successful Phase 2 baseline
```

```text
PHASE 2: PASS
PHASE 3: BLOCKED — awaiting explicit human authorization
STOP — do not implement v3 / ThinLTO overlay / CSIR / custom toolchains / benchmarks
```

Measured memory profile is for **this** successful runner only. Do **not** claim it is the minimum required hardware.

## GHA run 33938729218 (SUCCESS — Phase 3 x86-64-v3)

Authoritative Phase 3 close-out. Workflow: **Windows x86-64-v3 (self-hosted manual)** / commit `627e036` / conclusion **SUCCESS**.

Control (Phase 2): run `33895224558` / SHA256 `455886377761ae45f4bcc250021ce9a20858eb1811d3a99936e4bf076829c054`.

### Compiler probes (pinned image toolchain)

| Probe | Result |
|-------|--------|
| Clang `21.1.8` `--target=x86_64-pc-windows-msvc` `-march=x86-64-v3` | **PASS** (effective `-target-cpu x86-64-v3`) |
| rustc `1.97.1` `--print target-cpus` lists `x86-64-v3`; `-C target-cpu=x86-64-v3` compile | **PASS** (`RUST_V3_DIRECT_TARGET=SUPPORTED`) |

### Effective build evidence

| Layer | Requested | Proven |
|-------|-----------|--------|
| C (`clang-cl` target) | `-march=x86-64-v3` | **true** (OS_CFLAGS + invocation log) |
| C++ (`clang-cl -TP`) | `-march=x86-64-v3` | **true** (OS_CXXFLAGS + invocation log) |
| Rust (windows-msvc) | `-C target-cpu=x86-64-v3` | **true** (RUSTFLAGS + rustc log) |
| Host/target separation | host without v3 | **true** (HOST_* clean; no host march/cpu leak) |

**Not sufficient:** AVX2/BMI/FMA bytes in the PE alone.

Upstream semantics preserved: `windows.profdata` + `--enable-profile-use`; no `--enable-lto`; gkrust Finished release (~67m) → upstream Rust LTO preserved; no CSIR / ThinLTO overlay.

### Package

| Field | Value |
|-------|-------|
| filename | `librewolf-155.0-1-windows-x86_64-package.zip` |
| bytes | **158,453,627** |
| SHA-256 | `9f8bf1f1ca45b4a3e8c135c540155f6f5622498d71b7d4467d82e8170fb2f61a` |
| structure | zip OK; `librewolf.exe` MZ PE; `xul.dll`; `omni.ja` |
| GHA artifact | `v3-windows-x64-self-hosted` (~158,764,789 bytes wrapper) |

### Memory (same self-hosted class; not a universal minimum)

| Metric | Value |
|--------|-------|
| MemTotal | 32,646,784 kB (~31.13 GiB) |
| SwapTotal | 8,388,608 kB (~8 GiB) |
| memory.peak | 29,694,058,496 bytes (~27.65 GiB) |
| peak swap use | ~2,853,756,928 bytes (~2.66 GiB) |
| oom / oom_kill | **0 / 0** |

### Phase 2 structural comparison

Same package layout (`librewolf/` tree with exe/dll/omni). Size delta vs Phase 2 control (~158.77 MiB → ~151.1 MiB compressed zip bytes as recorded). Hashes differ (expected). **No performance claims.**

```text
PHASE 3: PASS
NEXT: BLOCKED — ThinLTO / CSIR / custom toolchains / benchmarks require new human authorization
STOP
```

Prior failed attempts (historical): `33927389796` (CC=*.sh configure reject); `33929591494` (full package built; CI false-failed on pipefail PE check — fixed in `a1936cc`/`627e036`).

