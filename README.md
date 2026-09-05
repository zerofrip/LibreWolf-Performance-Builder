# LibreWolf Performance Builder

Reproducible build/optimization overlay for Windows x64 LibreWolf.

This is **not** an official LibreWolf project. It wraps upstream LibreWolf `source` + `bsys6` without vendoring the full Firefox tree.

## Status

| Phase | Status |
|-------|--------|
| 0 Research | Done — see [docs/RESEARCH.md](docs/RESEARCH.md) |
| 1 Plan | Done — see [docs/PLAN.md](docs/PLAN.md) |
| 2 Upstream-equivalent Windows x64 baseline | **PASS** — closed on self-hosted run `33895224558` (see [docs/EVIDENCE.md](docs/EVIDENCE.md)) |
| 3 Windows x64 x86-64-v3 baseline | **PASS** — self-hosted run `33938729218` (see EVIDENCE.md) |
| 4 Windows x64 x86-64-v3 + ThinLTO | **PASS** — self-hosted run `33947898216` (see EVIDENCE; attempt 1 `33946910750` failed pre-compile) |
| 5 CSIR PGO feasibility PoC | **PASS** — standalone Windows-target pipeline proven (see EVIDENCE); not production LibreWolf CSIR |
| 6 Full-tree C/C++ CSIR integration PoC | **IN PROGRESS** — Stage A/B **PASS** (incl. Windows CSIR training → `cs.profdata`); Stage C/D not started |
| 7+ (benchmarks / Rust CSIR / …) | **BLOCKED** — awaiting explicit human authorization |

## Quick pins

See [`upstream/metadata.json`](upstream/metadata.json).

## License

Upstream LibreWolf/Firefox code remains under MPL 2.0. Overlay scripts/docs in this repository are also intended to be MPL-2.0-compatible; see `LICENSE` when added.











