#!/usr/bin/env bash
# Record toolchain paths/versions for Phase 2 evidence. Fail if critical tools missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/artifacts/toolchain-probe.txt}"
mkdir -p "$(dirname "$OUT")"

{
  echo "=== toolchain probe ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "HOME=${HOME:-}"
  echo "MOZBUILD=${MOZBUILD:-}"
  echo "MOZBUILD_STATE_PATH=${MOZBUILD_STATE_PATH:-}"
  echo "PATH=${PATH:-}"
  echo
  echo "--- expected image layout ---"
  for p in \
    /root/.mozbuild \
    /root/.mozbuild/win-cross/vs \
    /root/.mozbuild/clang/bin/clang \
    /root/.mozbuild/wine/bin/widl \
    /root/.mozbuild/fxc2/bin/fxc2.exe \
    /root/.cargo/bin/rustc \
    /root/.cargo/bin/cargo
  do
    if [[ -e "$p" ]]; then
      echo "OK  $p"
    else
      echo "MISS $p"
    fi
  done
  echo
  echo "--- MOZBUILD tree (depth 2) ---"
  if [[ -d "${MOZBUILD:-/root/.mozbuild}" ]]; then
    find "${MOZBUILD:-/root/.mozbuild}" -maxdepth 2 \( -type d -o -type f \) 2>/dev/null | sort | head -200
  else
    echo "MOZBUILD directory missing"
  fi
  echo
  echo "--- versions ---"
  command -v clang >/dev/null && clang --version | head -2 || echo "clang: missing"
  command -v clang++ >/dev/null && clang++ --version | head -1 || echo "clang++: missing"
  command -v rustc >/dev/null && rustc --version || echo "rustc: missing"
  command -v cargo >/dev/null && cargo --version || echo "cargo: missing"
  command -v widl >/dev/null && widl -h 2>&1 | head -1 || echo "widl: missing-from-PATH (may still be at MOZBUILD/wine/bin/widl)"
  echo "WINSYSROOT candidate: ${MOZBUILD:-/root/.mozbuild}/win-cross/vs"
  ls -la "${MOZBUILD:-/root/.mozbuild}/win-cross/vs" 2>/dev/null | head -20 || echo "WINSYSROOT missing"
} | tee "$OUT"

# Hard requirements for Windows cross image builds
[[ -d "${MOZBUILD:-/root/.mozbuild}/win-cross/vs" ]] \
  || { echo "ERROR: Windows SDK/sysroot missing under MOZBUILD" >&2; exit 1; }
command -v clang >/dev/null || [[ -x /root/.mozbuild/clang/bin/clang ]] \
  || { echo "ERROR: clang not found" >&2; exit 1; }
command -v rustc >/dev/null || [[ -x /root/.cargo/bin/rustc ]] \
  || { echo "ERROR: rustc not found" >&2; exit 1; }

echo "Toolchain probe OK -> $OUT"
