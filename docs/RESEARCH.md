# Phase 0 — Research audit

Status key used below:

- **CONFIRMED** — verified against current upstream files/docs/commits
- **INFERRED** — reasonable conclusion from evidence, not a hard guarantee
- **EXPERIMENTAL** — intended for later A/B work; not baseline
- **UNKNOWN** — not yet demonstrated; must not be treated as fact

Pinned revisions for this audit (also in `upstream/`):

| Component | Pin |
|-----------|-----|
| LibreWolf version | `155.0-1` |
| Firefox version | `155.0` |
| source.git | `03ba053934d5f6c7a11cb472424017caafd607e9` (codeberg.org/librewolf/source) |
| bsys6 | `1ca738899aeece8aad2f2811cbb00b707786ee33` (gitlab.com/librewolf-community/browser/bsys6) |
| Source tarball | `https://librewolf.dev/api/packages/librewolf/generic/librewolf-source/155.0-1/librewolf-155.0-1.source.tar.gz` |
| Source tarball SHA-256 | `5d951d8071ef6bcc4eab8bba1492e269af728c83586437ec2a7db11d46be36f6` |

---

## 1. Current LibreWolf build architecture

**CONFIRMED**

LibreWolf is assembled as:

```text
Firefox release source tarball
  → librewolf/source patches + branding + settings
  → librewolf-$VERSION.source.tar.gz
  → bsys6 (Docker or host) mach build / package
  → platform artifacts
```

Evidence:

- `source/README.md` overview diagram and `make dir` / `make all` flow
- `source/.forgejo/workflows/source-release.yaml` publishes `librewolf-source` generic packages
- `bsys6/README.md` command graph: `source → build → package → setup|msix|portable|deb|rpm`

Active mirrors: Codeberg (`librewolf/source`, `librewolf/bsys6`) and GitLab community mirrors. Binary packages for `155.0-1` exist under Codeberg package name `librewolf`.

---

## 2. How bsys6 builds Windows x86_64

**CONFIRMED**

- Host: x86_64 Linux only (`bsys6/README.md`)
- Env: `TARGET=windows`, `ARCH=x86_64` → `MOZ_TARGET=x86_64-pc-mingw32` (`src/exports/target.sh`)
- Prepare: Windows cross deps, rustup targets `x86_64-pc-windows-msvc` (+ arm64/i686), Mozilla toolchain artifacts, WinSDK, Chocolatey (`src/prepare.sh`)
- Mozconfig composition (`src/source.sh`):
  1. backup of tarball `mozconfig`
  2. `ac_add_options --target=$MOZ_TARGET`
  3. append `assets/windows.mozconfig`
  4. optional `LTO` → Windows uses `--enable-lto=thin`
- Build: `./mach build` inside source dir (`src/build.sh`)
- Package: multi-locale package; Windows artifact is `librewolf-*.zip` (`src/package.sh`)

`assets/windows.mozconfig` sets bootstrap, WinSYSROOT, MIDL/FXC, `MOZ_APP_REMOTINGNAME=LibreWolf`.

Official release workflow uses container `codeberg.org/librewolf/bsys6:windows` on self-hosted runner `epsilon` (`.forgejo/workflows/build-release.yml`).

---

## 3. Host OS requirements

**CONFIRMED**

- Primary: Linux x86_64
- `prepare` supported for Arch/Debian-based; others manual
- Windows-on-Windows build: not well tested (`source/README.md`, archived Windows wiki)
- Docker path: `./bsys6_docker` + prebuilt images

**INFERRED**

GitHub-hosted Ubuntu can host the cross build if disk/RAM suffice and the Windows container image (or equivalent toolchain bootstrap) is available.

---

## 4. Current Firefox / LibreWolf PGO

**CONFIRMED**

LibreWolf upstream mozconfig (`source/assets/mozconfig`) has **no** `MOZ_PGO`, `--enable-profile-generate`, or `--enable-profile-use`.

Firefox supported path (`firefox-source-docs` + `build/moz.configure/lto-pgo.configure`):

- `MOZ_PGO=1` ≈ instrumented build → `build/pgo/profileserver.py` → profile-use build
- Flags for Clang: `-fprofile-generate` / `-fprofile-use=<profdata>`
- Windows target: also `-mllvm -enable-name-compression=false` for cross-compile profile readability
- Cross-language (Rust) PGO requires `=cross` choice

Firefox tree contains **no** CSIR / `-fcs-profile-generate` usage (code search empty at audit time).

---

## 5. Current LTO

**CONFIRMED**

- bsys6: LTO is **opt-in** via env `LTO`
- Windows + LTO → `--enable-lto=thin` (`src/source.sh`)
- Non-Windows + LTO → `--enable-lto=full`
- Historical: Full LTO for Windows was removed because linking needed **>128 GB RAM** (commit `36f8c3df`); Thin was tried (`4c7d2b0c`)

Mozilla `lto-pgo.configure`: for automated PGO builds on x86_64 Windows/Linux, Full LTO may be selected when `MOZ_AUTOMATION` + PGO are set, based on Speedometer3 benefit. Thin is otherwise common.

**Implication for this project**

ThinLTO is the correct **initial default** here because of LibreWolf/GHA resource limits — **not** because Full LTO is invalid on Windows in Mozilla’s own automation.

---

## 6. Where compiler flags are injected

**CONFIRMED**

| Layer | Mechanism |
|-------|-----------|
| LibreWolf mozconfig | `export CFLAGS=...`, `export CXXFLAGS=...` (hardening: `-ftrivial-auto-var-init=zero -fwrapv`) |
| bsys6 | appends target + windows.mozconfig + optional LTO |
| Firefox configure | `PROFILE_GEN_*`, `PROFILE_USE_*`, `MOZ_LTO_*` from `lto-pgo.configure` |
| Rust | `RUSTFLAGS` option in `rust.configure`; host Rust programs should not get mozconfig RUSTFLAGS (Bug 1478969) |

**INFERRED**

Additional target ISA flags will likely follow LibreWolf’s existing CFLAGS/CXXFLAGS export pattern, but must be validated so host tools are not broken.

---

## 7. Target C/C++ flags vs host-tool flags

**CONFIRMED**

- Cross build: `--target=$MOZ_TARGET` separates target triple
- Global `CFLAGS`/`CXXFLAGS` in mozconfig are still applied broadly by Firefox’s build system
- Host vs target separation for Rust flags was explicitly fixed upstream; CFLAGS host leakage remains a known class of footgun

**UNKNOWN**

Exact blast radius of adding `-march=x86-64-v3` to LibreWolf’s existing CFLAGS export on Windows cross builds — must be measured in Phase 3.

---

## 8. Rust compilation behavior

**CONFIRMED**

- LibreWolf enables `--enable-rust-simd`
- Windows prepare installs `x86_64-pc-windows-msvc` (and others) via rustup
- Cross-language PGO needs `--enable-profile-generate=cross` / `--enable-profile-use=cross`
- Cross-language LTO uses `cross` choice with thin/full Rust LTO mode

**UNKNOWN / Phase 3 gate**

Whether the pinned rustc accepts `-C target-cpu=x86-64-v3` for `x86_64-pc-windows-*`. Must probe the real toolchain; do not assume.

Rust CSIR PGO is not available in upstream rustc (tracking discussions / Issue #118562 class). Initial CSIR scope is C/C++ only unless a custom toolchain is approved (human gate).

---

## 9. x86-64-v3 as target baseline

**INFERRED (safe as a goal; proof rules constrained)**

x86-64-v3 (AVX2/BMI1/BMI2/FMA/etc.) is widely supported on modern desktop CPUs and is used by community Firefox builders (e.g. ghazzor/firefox-builder).

**CONFIRMED constraint (approval condition)**

Presence of AVX2 instructions in the PE is **not** sufficient proof of an x86-64-v3 baseline, because Firefox includes runtime-dispatched AVX2 paths even in generic builds.

Primary proof must be: recorded target compiler/configure invocations and mozconfig application. Binary inspection is secondary only.

---

## 10. Integrating CSIR PGO

**CONFIRMED (Clang documentation)**

Clang Users Manual workflow:

1. `-fprofile-generate` → run → `llvm-profdata merge` → base profile  
2. `-fprofile-use=<base> -fcs-profile-generate` → run → CS profile  
3. `llvm-profdata merge` combining CS outputs with base → final `-fprofile-use`

`-fcs-profile-generate` instruments **after inlining**; cannot be combined with `-fprofile-generate` in the same compile.

**UNKNOWN (Phase 4 gate)**

Exact current merge semantics (weights, sparse/indexed forms, CSIR-specific merge flags) must be re-verified from authoritative LLVM/Clang docs/source **before** Phase 4 implementation. Do not assume a naive `merge base.profdata cs.profraw` is sufficient.

Firefox has no first-class CSIR switch; integration must be an overlay, not `MOZ_PGO=1` alone.

---

## 11. Windows profiling on GitHub-hosted runners

**INFERRED**

Native Windows runners can execute a packaged LibreWolf and write `LLVM_PROFILE_FILE` outputs.

**UNKNOWN**

- Timeout / GPU / sandbox limits for realistic workloads
- Whether Wine on Linux can collect usable Windows profiles (out of initial scope)

---

## 12. SkyKakapo / tete009 reproducibility without custom compilers

**CONFIRMED**

- SkyKakapo claims CSIR PGO (`cspgo` in release labels)
- Public baseline advertised as **x64 SSE3**, not x86-64-v3
- Patches ship inside the download’s Source folder
- Author rebranded away from “Firefox Private Builds” for trademark reasons

**UNKNOWN**

Whether their pipeline needs a custom LLVM/Rust, exact flag sequence, Thin vs Full LTO, and profile merge details. Requires inspecting a release Source tree (not done in Phase 0).

**INFERRED**

C/C++ CSIR using upstream Clang is reproducible in principle; SkyKakapo-specific patches/toolchains may not be.

---

## 13. GitHub Actions CPU / RAM / disk / runtime

**CONFIRMED**

- Firefox/LibreWolf object trees are tens of GB; stock ubuntu-latest free space is often ~14 GB before cleanup
- Community builders reclaim space by deleting Android/dotnet/CodeQL/etc. (`ghazzor/firefox-builder` workflow)
- LibreWolf official CI uses self-hosted `epsilon` + Docker images — evidence hosted runners are marginal for full matrix

**INFERRED**

Windows Full LTO is infeasible on GHA RAM; ThinLTO may still stress linkers. Multi-stage PGO multiplies disk and time.

---

## 14. Licensing / trademark

**CONFIRMED**

- Code: MPL 2.0 (LibreWolf / Firefox)
- Mozilla trademarks: modified Firefox must not pretend to be Firefox (SkyKakapo migration notes cite this)
- LibreWolf name/branding: distributing modified binaries under the LibreWolf name without community understanding is a policy risk

**INFERRED**

Safe default: unofficial overlay project, clear disclaimer, no claim of official LibreWolf status. Public release naming is a **human gate**.

---

## 15. Risks to LibreWolf privacy / security behavior

**CONFIRMED**

Privacy surface lives in:

- `settings/librewolf.cfg`
- `settings/distribution/policies.json` (telemetry disabled, uBO forced install, etc.)
- compile-time patches (e.g. `disable-data-reporting-at-compile-time.patch`)
- mozconfig telemetry/`MOZ_*` reporting disables

**Risks**

- Copying firefox-builder feature disables (`--disable-accessibility`, etc.) could diverge from LibreWolf security/UX posture
- PGO training profiles that flip prefs could bake non-default behavior into layout/JIT paths (**INFERRED**)
- Silent fallback from optimized configs would hide divergence

Performance regressions are acceptable. Privacy/security regressions are not.

---

## Reference project notes (firefox-builder)

**CONFIRMED**

- Linux native only; not a Windows cross CI template
- Disk cleanup pattern is useful
- mozconfig uses `MOZ_PGO=1`, `--enable-lto=full`, exports `-march=x86-64-v3`, Rust `target-cpu=x86-64-v3`
- Optimization level in mozconfig COMMONFLAGS is `-O2` (not `-O3` despite informal descriptions)
- Disables several features LibreWolf does not — **do not copy**

---

## Incorrect assumptions corrected by this audit

1. Upstream LibreWolf Windows builds are not PGO by default.  
2. Firefox `MOZ_PGO=1` is not CSIR.  
3. Full LTO is valid in Mozilla automation for some Win/Linux PGO builds, but LibreWolf/GHA cannot treat it as default.  
4. `FORGE_URL=https://codeberg.org` (bsys6 default) **404s** for current `librewolf-source` packages; working host is `https://librewolf.dev`.  
5. AVX2 bytes in a binary ≠ x86-64-v3 baseline.  
6. Rust `-C target-cpu=x86-64-v3` is unproven until probed on the pinned Windows target rustc.

---

## Open UNKNOWN register (must stay open until closed with evidence)

| ID | Item |
|----|------|
| U1 | Windows `.profraw` consumable by Linux cross Clang without silent corruption |
| U2 | Exact Clang CSIR merge semantics for current LLVM used by Mozilla toolchain |
| U3 | SkyKakapo custom compiler requirements |
| U4 | GHA-hosted complete Windows LibreWolf build feasibility (disk/time) |
| U5 | rustc support for `x86-64-v3` on `x86_64-pc-windows-*` |
| U6 | Wine-based Windows profile collection viability |
