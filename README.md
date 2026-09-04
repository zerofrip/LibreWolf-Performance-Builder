# LibreWolf Performance Builder

Reproducible build/optimization overlay for Windows x64 LibreWolf.

This is **not** an official LibreWolf project. It wraps upstream LibreWolf `source` + `bsys6` without vendoring the full Firefox tree.

## Status

| Phase | Status |
|-------|--------|
| 0 Research | Done — see [docs/RESEARCH.md](docs/RESEARCH.md) |
| 1 Plan | Done — see [docs/PLAN.md](docs/PLAN.md) |
| 2 Upstream-equivalent Windows x64 baseline | **PASS** — closed on self-hosted run `33895224558` (`librewolf-155.0-1-windows-x86_64-package.zip`; see [docs/EVIDENCE.md](docs/EVIDENCE.md)) |
| 3+ Optimizations (v3, CSIR PGO, …) | **BLOCKED** — awaiting explicit human authorization |

## Quick pins

See [`upstream/metadata.json`](upstream/metadata.json).

## License

Upstream LibreWolf/Firefox code remains under MPL 2.0. Overlay scripts/docs in this repository are also intended to be MPL-2.0-compatible; see `LICENSE` when added.





