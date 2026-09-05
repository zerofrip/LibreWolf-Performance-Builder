# Phase 1 — Architecture plan

This document is the fixed plan for the LibreWolf Performance Builder overlay repository. It incorporates the Phase 0 audit and the human approval conditions dated 2026-09-03.

## Goal

Produce a reproducible **optimization overlay** (not a permanent LibreWolf fork) that builds Windows x64 LibreWolf with evidence-backed performance options while preserving upstream privacy/security behavior.

## Initial production target (when later phases are authorized)

```text
Windows
x86_64 only
x86-64-v3          (Phase 3+)
ThinLTO           (default LTO mode)
CSIR PGO          (Phase 4+, only after PoC evidence)
```

Phase 2 (current authorization) targets an **upstream-equivalent** Windows x64 package with **no OUR** v3 / CSIR / overlay-LTO flags.

Upstream-equivalent is **not** “PGO off / LTO off”:

```text
- pinned windows.profdata (when present) → --enable-profile-use
- Firefox rust.mk → gkrust -Clto / codegen-units=1 on release staticlib
- bsys6 LTO env default false → no --enable-lto C/C++ cross LTO
```

## Non-goals (default OFF / experimental)

```text
-O3
Full LTO
-march=native
x86-64-v4 / AVX-512
mimalloc
BOLT / Propeller
AutoFDO / SamplePGO
custom Rust or LLVM toolchains
```

## Repository shape

```text
optimized overlay repo
├── configs/          mozconfig fragments
├── patches/          perf-only patches (none by default)
├── scripts/          fetch / inject / build / prove / check
├── upstream/         pins + metadata only
├── docs/             RESEARCH, PLAN, evidence
└── .github/workflows/
```

Conceptually:

```text
Mozilla Firefox → LibreWolf source → bsys6 → our overlay → Windows x64 artifact
```

## Upstream pinning

- Pin `bsys6` git revision (`upstream/bsys6.rev`)
- Pin LibreWolf source version + preferred source.git rev
- Pin source tarball URL + SHA-256
- Record toolchain versions after each successful CI run into `versions/` / build metadata

**CONFIRMED operational detail:** set `FORGE_URL=https://librewolf.dev` (or set absolute `SOURCE_URL`) because bsys6’s default `https://codeberg.org` package URL 404s for current `librewolf-source` artifacts.

## Phase map and authorization

| Phase | Content | Authorization |
|-------|---------|---------------|
| 0 | RESEARCH.md | Done / authorized |
| 1 | PLAN.md | Done / authorized |
| 2 | Upstream-equivalent Windows x64 CI | **PASS** (self-hosted run `33895224558`) |
| 3 | x86-64-v3 separate config | **PASS** (self-hosted run `33938729218`; C/C++/Rust proven) |
| 4 | ThinLTO (Windows x64 + x86-64-v3) | **AUTHORIZED** — first full attempt `33946910750` **FAILED** before compile (see EVIDENCE); corrected workflow not auto-retried |
| 4–5 | CSIR PGO + CI topology | **Not authorized** until CSIR PoC evidence + separate human authorization |
| 6+ | Workload / privacy / bench / update automation | Not authorized yet |

## Phase 2 design (authorized)

Smallest viable path:

1. Clone pinned bsys6
2. Fetch pinned LibreWolf source tarball with checksum verification
3. Build with `TARGET=windows ARCH=x86_64`
4. Package zip (and optional portable later)
5. Fail loudly on pin/checksum/config mismatch — no silent fallback
6. Emit metadata: versions, disk samples, duration, artifact hashes, proven optimization layers

### Infrastructure (updated after OOM CONFIRMED)

**CONFIRMED:** standard public GitHub-hosted `ubuntu-latest` is **INSUFFICIENT** for the upstream-equivalent Windows build (run `33862245103`):

```text
MemTotal ≈ 15.62 GiB, SwapTotal ≈ 3.0 GiB
memory.peak ≈ 14.56 GiB, oom_kill = 1 during gkrust -Clto
```

Policy:

- Push/PR: **local-validate only** (no automatic full browser build)
- Full Phase 2 package: **self-hosted** high-memory runner (labels `self-hosted,linux,x64,librewolf-builder`) via reusable workflow
- Standard full build: **manual diagnostics only** (`UNDERSTAND-OOM`); do not retry to “make CI green”
- Do **not** disable upstream PGO / Rust gkrust LTO / `windows.profdata` / codegen-units

Resource guidance (updated after measured self-hosted PASS `33895224558`):

```text
~31 GiB RAM + 8 GiB swap: proven once (peak ≈28.39 GiB; not a universal minimum)
64 GiB RAM: preferred headroom for Phase 2 / future PGO/CSIR
128 GiB+:   future Full C/C++ LTO only; not required for current Phase 2
```

See `docs/SELF-HOSTED.md` and `docs/EVIDENCE.md`. Phase 3 is **PASS**. Phase 4 ThinLTO is **authorized** but the first self-hosted attempt failed before compile (workflow `LTO=false` vs Phase 2 baseline env guard). CSIR / Full LTO / further phases remain **BLOCKED** until explicit human authorization.

GHA standard public `ubuntu-latest` is **INSUFFICIENT** for upstream-equivalent `gkrust` Rust LTO (OOM CONFIRMED, run `33862245103`). Prefer self-hosted with measured headroom; do not weaken baseline flags.

## Phase 3 requirements (amended — implement only after probe)

### 3.1 Rust target-cpu probe (mandatory first)

Do **not** assume Rust accepts `-C target-cpu=x86-64-v3`.

Before enabling any Rust ISA flags:

1. Use the **exact pinned rustc** from the bootstrap/toolchain used for Windows cross builds
2. Probe against the real Windows target triple in use (`x86_64-pc-windows-msvc` and/or the mingw configure target as applicable)
3. Record supported CPUs/features (e.g. `rustc --print target-cpus` / `target-features` for that target)
4. If `x86-64-v3` is unsupported, **stop** and document alternatives (feature list, different baseline, or C/C++-only v3) — do not invent flags

### 3.2 Proving x86-64-v3 is active

Primary evidence (required):

- mozconfig fragment contents actually applied
- configure/build logs showing the intended target compiler invocations / flags

Secondary evidence only:

- binary / disassembly inspection

Do **not** treat “AVX2 instruction exists in the PE” as proof of an x86-64-v3 baseline. Firefox can contain runtime-dispatched AVX2 code in generic builds.

Keep generic x86_64 and x86-64-v3 as separate configs/artifacts for comparison.

### 3.3 ThinLTO vs Full LTO documentation

- **Overlay default (later phases):** ThinLTO (`--enable-lto=thin`) for resource-constrained builders
- **Current bsys6 when `LTO=true` (tag `155.0-1` / `24c40ff`):** `--enable-lto=full,cross` (not thin)
- **Mozilla:** may select Full LTO for automation+PGO x86_64 Win/Linux when `--enable-lto` is enabled (`lto-pgo.configure`)
- **LibreWolf history:** Windows Full C/C++ LTO link needed >128 GB (`36f8c3df`) — keep Full as experimental here
- **Always-on Firefox behavior:** `gkrust` release staticlib uses Rust `-Clto` via `rust.mk` even when bsys6 `LTO=false` — this is part of the upstream-equivalent baseline, not an overlay

## Infrastructure options (evaluate; do not apply without approval)

Ranked for Phase 2 completion while preserving upstream PGO + Firefox Rust gkrust LTO:

| Rank | Option | Upstream fidelity | Cost | Repro | Maintenance | Future CSIR PGO |
|------|--------|-------------------|------|-------|-------------|-----------------|
| 1 | **B. Self-hosted high-RAM runner** (epsilon-like) | Highest (matches official topology) | CapEx/OpEx | High if documented | Medium | Best (local profiles + large link) |
| 2 | **A. GitHub larger runners** (e.g. 16–64 GiB+) | High (same scripts/image) | Pay-per-minute | High | Low | Good if RAM enough for CSIR stages |
| 3 | **E. Official LibreWolf CI model** (epsilon + bsys6:windows) | Exact | Needs access | High | Low for us if we can use it | N/A unless we gain runner access |
| 4 | **C/D. External / container swap** | High fidelity of flags; slower | Low | Medium (swap availability varies) | Low | Marginal help for peak RSS |
| 5 | **F. Reusable prebuilt upstream artifacts** | Lower for *our* compile proof | Low | Medium | Medium | Poor — skips the build we must validate |

GHA standard public `ubuntu-latest` is **INSUFFICIENT** for upstream-equivalent `gkrust` Rust LTO (OOM CONFIRMED, run `33862245103`, MemTotal ~15.62 GiB, peak ~14.56 GiB, `oom_kill=1`). Prefer measured self-hosted capacity (run `33895224558` succeeded at ~31 GiB / peak ~28.39 GiB); do not weaken baseline flags.


## Phase 4–5 gates (not authorized yet)

### 4.1 CSIR merge semantics

Before implementing CSIR:

- Re-read authoritative current Clang/LLVM documentation and/or source for CSIR PGO
- Verify exact merge requirements for combining IR and CS profiles
- Do **not** assume simply merging `base.profdata` and CS profile data is sufficient
- Present a minimal deterministic PoC with logs proving instrumentation, merge, and use

### 4.2 Profile compatibility

Windows-profile → Linux-cross-build consumption remains **UNKNOWN** until a minimal deterministic PoC demonstrates it. Incompatibilities must be documented, not papered over.

### 4.3 Failure policy

Never silently fall back from CSIR PGO to normal PGO, or from x86-64-v3 to generic x86_64.

## Privacy / security invariants (mandatory in later authorized phases)

Optimized builds may differ from upstream LibreWolf only for performance/build mechanics by default.

Automated checks (when authorized) must cover prefs, policies, telemetry configuration, uBlock Origin integration, RFP-related settings, and patch set drift.

Any intentional privacy/security difference requires explicit docs and human approval before becoming default.

## Human decision gates

Stop for approval before:

- weakening LibreWolf privacy/security
- custom LLVM/Rust
- permanent Firefox/LibreWolf source fork
- product name / trademark changes
- defaulting experimental ISA or Full LTO
- publishing public binary releases
- requiring self-hosted runners

## Commit strategy

Small commits per working phase. Do not squash unrelated phases.

## Immediate next steps after this document

1. Commit Phase 0 + Phase 1 docs separately from code
2. Implement Phase 2 scripts + GitHub Actions baseline workflow
3. Run locally available validation
4. Stop and report evidence before Phase 3/4 work

## Compatibility note (Firefox 155 / bsys6)

Phase 2 must pin **Codeberg** bsys6 tag `155.0-1` (`24c40ff…`), which emits `x86_64-pc-windows-msvc`.

Do not use stale GitLab `master` revisions that still emit `x86_64-pc-mingw32` — Firefox 155 configure rejects that triple.

`scripts/verify-windows-target.sh` fails the job if the obsolete mingw triple would be generated. No silent rewrite.

Upstream bsys6 may inject `--enable-profile-use` when `assets/windows.profdata` (Git LFS) is present; that is upstream behavior, not an overlay optimization.





