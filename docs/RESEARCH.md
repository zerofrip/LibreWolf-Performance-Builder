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
| bsys6 | `24c40ffaa25b558e4c5ce9f326bc4466ba7608bc` (codeberg.org/librewolf/bsys6 tag `155.0-1`) |
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
- Env: `TARGET=windows`, `ARCH=x86_64` → `MOZ_TARGET=x86_64-pc-windows-msvc` (`src/exports/target.sh` at tag `155.0-1` / commit `0ed119d`)
- Prepare: Windows cross deps, rustup targets `x86_64-pc-windows-msvc` (+ arm64), Mozilla toolchain artifacts, WinSDK (`src/prepare.sh`, `Dockerfile.windows`)
- Mozconfig composition (`src/source.sh` @ `24c40ff`):
  1. backup of tarball `mozconfig`
  2. `ac_add_options --target=$MOZ_TARGET`
  3. append `assets/windows.mozconfig`
  4. optional `LTO=true` → `--enable-lto=full,cross` (both Windows and non-Windows)
  5. if `assets/$TARGET.profdata` exists → `--with-pgo-profile-path=...` + `--enable-profile-use`
- Build: `./mach build` inside source dir (`src/build.sh`)
- Package: multi-locale package; Windows artifact is `librewolf-*.zip` (`src/package.sh`)

`assets/windows.mozconfig` sets sandbox, WinSYSROOT, MIDL/FXC, l10n base.

### Official Windows CI model (bsys6 `.forgejo/workflows/build-release.yml` @ `24c40ff`)

**CONFIRMED**

| Item | Evidence |
|------|----------|
| Runner | `runs-on: epsilon` (self-hosted Forgejo runner label) |
| Container | `librewolf.dev/librewolf/bsys6:windows` |
| Matrix | `arch: [x86_64, arm64]`, `max-parallel: 2` |
| Command | `./bsys6 package setup msix portable nupkg` |
| Overlay C/C++ LTO | `LTO: ${{ inputs.lto }}` with workflow_dispatch default **`false`** |
| Container memory/swap | **not** set in the workflow YAML (no `options: --memory=...`, no swap config) |
| Machine class / RAM | **UNKNOWN** — no public epsilon RAM/CPU/swap docs found in bsys6 README or workflow |
| Historical Full LTO RAM | commit `36f8c3df` message: *“remove LTO for Windows since it is taking more than 128 GB to link”* |

Official releases therefore run on a **larger unknown self-hosted class** (`epsilon`), not GitHub-hosted `ubuntu-latest`.

**GitHub-hosted RAM (documentation vs authoritative):**

- Public-repo standard `ubuntu-latest` is documented by GitHub as **4 CPUs / 16 GB RAM** ([GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)).
- Private-repo standard `ubuntu-latest` is documented as **2 CPUs / 8 GB RAM**.
- This repository is **public**, so the *documented* host VM class is 4/16 — but jobs use `container:`, so the **authoritative** limit is the process-visible cgroup (`memory.max` / `memory.peak` / `memory.events`) captured in `artifacts/memory-summary.json`. Do **not** assume host RAM equals container cgroup limit.

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

**CONFIRMED (corrected 2026-09-04)**

LibreWolf source tarball mozconfig still has no hand-written PGO flags, **but bsys6 injects upstream profile-use when Git LFS profdata is present**:

```text
# bsys6 src/source.sh @ 24c40ff
if [ -f "$BSYS6/../assets/$TARGET.profdata" ]; then
  ac_add_options --with-pgo-profile-path=...
  ac_add_options --enable-profile-use
fi
```

- `assets/windows.profdata` is a Git LFS object (~116 668 272 bytes per LFS pointer oid `8aa61ee6…`)
- Official Forgejo workflow runs `git lfs pull` before Windows builds
- GHA run `33854319687` configure log shows both flags active; also `Activating PGO-based orderfile`

Firefox supported path (`build/moz.configure/lto-pgo.configure` on mozilla-firefox/firefox `release`):

- `--enable-profile-use` / `--with-pgo-profile-path`
- Flags for Clang: `-fprofile-use=<profdata>` (+ Windows name-compression note for generate)
- Cross-language (Rust) PGO requires `=cross` choice (`MOZ_PGO_RUST`) — **not** what bsys6 passes today (plain `--enable-profile-use`)

Firefox tree contains **no** CSIR / `-fcs-profile-generate` usage (Phase 0 search).

---

## 5. Current LTO (four distinct layers)

**CONFIRMED — distinguish carefully**

| Layer | How enabled | Official Windows default (`LTO` input false) | Run 33854319687 |
|-------|-------------|-----------------------------------------------|-----------------|
| Overlay LTO (this repo) | our mozconfig / env | N/A | **OFF** |
| bsys6 `--enable-lto=…` | `LTO=true` → `--enable-lto=full,cross` (`src/source.sh` @ `24c40ff`) | **OFF** (workflow default false) | **OFF** (configure options list has no `--enable-lto`) |
| Upstream C/C++ LTO | Firefox `MOZ_LTO` from `--enable-lto` | inactive unless LTO input true | **INACTIVE** |
| Upstream Rust `gkrust` LTO | Firefox `config/makefiles/rust.mk` adds `-Clto` (+ later `codegen-units=1`) for release staticlib when **not** `MOZ_LTO_RUST_CROSS` | **ACTIVE** (expected) | **ACTIVE** (`rustc … -Clto … -C codegen-units=1`) |

Evidence for Rust default LTO (mozilla-firefox/firefox `release` `config/makefiles/rust.mk`):

```make
# Enable link-time optimization for release builds, but not when linking
# gkrust_gtest. And not when doing cross-language LTO.
ifndef MOZ_LTO_RUST_CROSS
...
cargo_rustc_flags += -Clto$(if $(filter full,$(MOZ_LTO_RUST_CROSS)),=fat)
...
$(TARGET_RECIPES) $(HOST_RECIPES): RUSTFLAGS += -C codegen-units=1
```

So **`gkrust -Clto -C codegen-units=1` is expected in the official Windows baseline even when bsys6 `LTO=false`.** It is not proof that overlay LTO or bsys6 `--enable-lto` is on.

bsys6 history:

- `36f8c3df` — remove unconditional Windows `--enable-lto=full` (*“taking more than 128 GB to link”*)
- `24c40ff` — when `LTO=true`, use `--enable-lto=full,cross` (cross-language)

Mozilla `lto-pgo.configure`: if `--enable-lto` is passed with empty/`cross` only **and** `MOZ_AUTOMATION` + PGO + Win/Linux x86_64, Full may be selected. That path does **not** apply when `--enable-lto` is absent.

**Implication for this project**

Do not disable upstream profile-use or Firefox default Rust `gkrust` LTO merely to fit GHA. ThinLTO remains the preferred **overlay** default when we later opt into `--enable-lto`, because LibreWolf documented >128 GB for Windows Full C/C++ LTO link.

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

**PROVEN (Phase 5 PoC — Clang 21.1.8 / x86_64-pc-windows-msvc)**

Pinned toolchain CSIR pipeline on a minimal Windows-target program:

1. `-fprofile-generate` → Windows run → `.profraw` → `llvm-profdata merge` → `base.profdata`
2. `-fprofile-use=base.profdata -fcs-profile-generate=<dir>` → Windows run → CS `.profraw`
3. `llvm-profdata merge base.profdata cs.profdata` → `combined.profdata`
4. `-fprofile-use=combined.profdata` final PE (consumption proven by PE hash ≠ no-profile build)

`-fprofile-generate` and `-fcs-profile-generate` in the **same** compile are **rejected** (`invalid argument '-fcs-profile-generate' not allowed with '-fprofile-generate'`).

CS profiles require `llvm-profdata show --showcs` (without it: Total functions = 0).

**UNPROVEN:** using upstream `windows.profdata` as the CSIR Stage-A base for a future LibreWolf tree CSIR build (IR-format compatible; source/hash correspondence not established).

**IN PROGRESS (Phase 6 — full-tree integration PoC)**

Authorized full-tree LibreWolf Windows x64 C/C++ CSIR pipeline using an **own matching** Stage-A IR profile. See `docs/PHASE6-INTEGRATION.md`.

**SOURCE-SUPPORTED (bsys6):** `src/source.sh` always injects `--enable-profile-use` + `assets/windows.profdata` when the asset exists; Phase 6 disables that asset during Stages A/B/D to keep a single profile authority.

**UNKNOWN until Phase 6 evidence closes:** full-tree resource peaks for Stage A/B, profile CFG matching across stages, and operational Windows training of the full browser.

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

1. ~~Upstream LibreWolf Windows builds are not PGO by default.~~ **Corrected:** when `assets/windows.profdata` (Git LFS) is present, bsys6 enables `--enable-profile-use` (run `33854319687`, `src/source.sh` @ `24c40ff`).
2. Firefox `MOZ_PGO=1` is not CSIR.
3. Full C/C++ LTO is valid in Mozilla automation for some Win/Linux PGO builds, but LibreWolf keeps `LTO` workflow-default **false**; when opted in (tag `155.0-1`) it uses `--enable-lto=full,cross` and historically needed >128 GB for Windows link (`36f8c3df`).
4. `FORGE_URL=https://codeberg.org` (bsys6 default) **404s** for current `librewolf-source` packages; working host is `https://librewolf.dev`.
5. AVX2 bytes in a binary ≠ x86-64-v3 baseline.
6. Rust `-C target-cpu=x86-64-v3` is unproven until probed on the pinned Windows target rustc.
7. Metadata `"lto": false` must **not** mean “no rustc `-Clto`”. Firefox `rust.mk` enables `gkrust` crate LTO for release staticlibs independently of bsys6 `LTO`.

### Upstream-equivalent Windows baseline (definition)

```text
LibreWolf upstream-equivalent Windows baseline:
- uses pinned upstream windows.profdata when bsys6 provides it (Git LFS);
- enables upstream --enable-profile-use / --with-pgo-profile-path;
- may compile gkrust with Firefox default -Clto / codegen-units=1 (rust.mk);
- does NOT set bsys6 LTO=true / --enable-lto unless explicitly opted in;
- contains no OUR optimization overlay (no x86-64-v3, no CSIR, no overlay LTO).
```

Do **not** strip upstream PGO or Firefox Rust gkrust LTO just to make GHA green unless explicitly authorized.

---


## GHA run 33754159563 — Windows target triple break (2026-09-03)

**CONFIRMED:** Firefox 155 rejects `x86_64-pc-mingw32` (`init.configure` `check_mingw_triplet`).

**CONFIRMED:** Pinned GitLab bsys6 `1ca7388` generated `x86_64-pc-mingw32` via `src/exports/target.sh`.

**CONFIRMED:** Run 33754159563 failed at configure; disk remained ~68–74 GB free (not ENOSPC).

**CONFIRMED:** Codeberg bsys6 commit `0ed119d` (`Use windows-msvc everywhere for x86_64`) and tag `155.0-1` (`24c40ff`) set Windows x86_64 to `x86_64-pc-windows-msvc`. That is the intended Linux-hosted Windows cross-build triple for current upstream (Rust/Docker already on `windows-msvc`).

**CONFIRMED:** Prefer updating the bsys6 pin to Codeberg `155.0-1` over maintaining a local mingw→msvc patch.

**UNKNOWN until rerun:** full GitHub-hosted baseline success after pin update.

## Open UNKNOWN register (must stay open until closed with evidence)

| ID | Item |
|----|------|
| U1 | Windows `.profraw` consumable by Linux cross Clang without silent corruption |
| U2 | Exact Clang CSIR merge semantics for current LLVM used by Mozilla toolchain |
| U3 | SkyKakapo custom compiler requirements |
| U4 | ~~GHA-hosted complete Windows LibreWolf build feasibility~~ → **CLOSED / INSUFFICIENT** on standard public ubuntu-latest (OOM CONFIRMED `33862245103`). **Self-hosted Phase 2 PASS** on run `33895224558` (~31 GiB host, peak ~28.39 GiB, `oom_kill=0`). |
| U5 | ~~rustc support for `x86-64-v3` on `x86_64-pc-windows-*`~~ → **CLOSED / SUPPORTED** (`rustc 1.97.1`, `-C target-cpu=x86-64-v3`, Phase 3 run `33938729218`) |
| U6 | Wine-based Windows profile collection viability |
| U7 | Official `epsilon` runner RAM / swap / cgroup memory limits (not published in bsys6) |
| U8 | ~~Whether cgroup oom_kill is readable on GHA container jobs~~ → **CLOSED**: readable (`oom_kill=1`). Kernel `dmesg` still often blocked (`Operation not permitted`). |

### Phase 6 status (Stage C)

- Stages A/B/C **PASS**; authoritative `combined.profdata` SHA256 `bd3b9602c8131568b7d95177f53748e09257655297b9fe7247dea330b55e56a9`.
- Stage D **NOT STARTED**.

### Phase 6 status (Stage D close)

- Phase 6 **PASS** (A/B/C/D).
- Final package SHA256 `e05238f21773a6739b23873d600ef7ac38aa52700096dbf633cec08972dbff35`.
- Benchmarking / release: **NOT AUTHORIZED**.
