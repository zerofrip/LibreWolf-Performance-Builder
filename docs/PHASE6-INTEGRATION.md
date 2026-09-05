# Phase 6 — Full-tree CSIR integration map

Status: design authority for Phase 6 implementation. Classify facts as noted.

## Control

- Phase 4 final: run `33947898216`, ThinLTO + v3 + upstream `windows.profdata` PGO
- Phase 5 PoC: CSIR pipeline proven on minimal Windows-target program (Clang 21.1.8)
- Phase 6 Stage A base: **own matching LibreWolf IR profile** (upstream `windows.profdata` **not** Stage-A authority)

## Upstream injection (SOURCE-SUPPORTED)

bsys6 `src/source.sh` when `assets/windows.profdata` exists:

```text
ac_add_options --with-pgo-profile-path=.../assets/windows.profdata
ac_add_options --enable-profile-use
```

Firefox `lto-pgo.configure`:

- `--enable-profile-generate` → `PROFILE_GEN_CFLAGS` ≈ `-fprofile-generate` (clang-cl `/clang:` prefix)
- `--enable-profile-use` + path → `PROFILE_USE_CFLAGS` ≈ `-fprofile-use=<path>`
- Cannot enable generate and use together
- **If `--enable-profile-generate`:** LTO is **disabled** (`Disabling LTO because --enable-profile-generate is specified`)
- `MOZ_PGO_RUST` only when profile-generate/use is given the `cross` choice (Phase 2–4 use plain profile-use → Rust PGO cross **off**)
- Rust gkrust `-Clto` still comes from `rust.mk` release path (independent of C++ `MOZ_LTO` being off during generate)

Firefox has **no** `--enable-csir`. Stage B CSIR flags must be overlay-injected (CFLAGS/CXXFLAGS) in addition to `--enable-profile-use`.

## Stage map

```text
Stage A (csir-base-gen)
  mozconfig: strip upstream profile-use; --enable-profile-generate; + v3 frag
  ThinLTO: OFF (Firefox disables LTO under profile-generate)
  Rust: gkrust -Clto as upstream release; no Rust CSIR
  package → Windows train → *.profraw → llvm-profdata merge → base.profdata

Stage B (csir-cs-gen)
  mozconfig: strip upstream windows.profdata; --enable-profile-use + --with-pgo-profile-path=base.profdata
  overlay: -fcs-profile-generate=<dir> on C/C++ (NOT -fprofile-generate)
  ThinLTO: OFF for this PoC stage unless proven required (avoid inventing; default OFF)
  package → Windows train (same workload) → CS *.profraw → cs.profdata

Stage C
  llvm-profdata merge base.profdata cs.profdata → combined.profdata

Stage D (csir-final)
  mozconfig: strip upstream windows.profdata; --enable-profile-use + combined.profdata
  + v3 + ThinLTO frags; CS generation OFF
  Rust: v3 + upstream gkrust -Clto
  package → Windows smoke
```

## Dual-profile rule (Stage D)

Exactly one C/C++ profile-use path: `combined.profdata`.  

**SOURCE-SUPPORTED:** `bsys6` `src/source.sh` always appends
`--enable-profile-use` + `assets/windows.profdata` when that file exists,
regardless of `mozconfig.backup` contents. Phase 6 therefore **renames** the
asset to `windows.profdata.lwpb-phase6-disabled` for the duration of Stages
A/B/D (`disable_upstream_profdata_asset` in `scripts/csir-fulltree/common.sh`),
then writes the stage-authoritative `--with-pgo-profile-path=...`.

Must remove/suppress bsys6 auto-injection of `assets/windows.profdata` for Stage B/D.

## Windows training

- Real Windows PE loader (WSL interop allowed; Wine forbidden)
- Deterministic local HTML/JS workload under `workloads/csir-train/`
- `LLVM_PROFILE_FILE` with non-colliding pattern
- Fresh profile directory per run

## Host vs target

| Role | Where |
|------|--------|
| Cross-compile, merge, package | Linux self-hosted (`librewolf-builder`) + `bsys6:windows` image |
| Instrumented / final browser execution | Windows (WSL→Windows or dedicated Windows host) |
| `llvm-profdata` | Pinned image Clang/LLVM 21.1.8 on Linux |
