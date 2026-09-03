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

