# LibreWolf Performance Builder

Reproducible build/optimization overlay for Windows x64 LibreWolf.

This is **not** an official LibreWolf project. It wraps upstream LibreWolf `source` + `bsys6` without vendoring the full Firefox tree.

## Status

| Phase | Status |
|-------|--------|
| 0 Research | Done — see [docs/RESEARCH.md](docs/RESEARCH.md) |
| 1 Plan | Done — see [docs/PLAN.md](docs/PLAN.md) |
| 2 Upstream-equivalent Windows x64 baseline | In progress |
| 3+ Optimizations (v3, CSIR PGO, …) | Gated — see PLAN.md |

## Quick pins

See [`upstream/metadata.json`](upstream/metadata.json).

## License

Upstream LibreWolf/Firefox code remains under MPL 2.0. Overlay scripts/docs in this repository are also intended to be MPL-2.0-compatible; see `LICENSE` when added.
