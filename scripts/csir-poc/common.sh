#!/usr/bin/env bash
# Shared helpers for Phase 5 CSIR PoC (Windows-target via pinned bsys6 image).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POC_SRC="${ROOT}/tests/csir-poc/csir_poc.c"
ART="${ROOT}/artifacts/csir-poc"
BIN="${ART}/bin"
PROF="${ART}/profiles"
IMG="${LWPB_BSYS6_IMAGE:-codeberg.org/librewolf/bsys6:windows}"
TARGET="${LWPB_WINDOWS_TARGET_X64:-x86_64-pc-windows-msvc}"
WIN_WORKDIR="${LWPB_CSIR_WIN_WORKDIR:-/mnt/c/Users/Public/lwpb-csir-poc}"

mkdir -p "$ART" "$BIN" "$PROF" "${ART}/meta"

json_sha256() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
}

require_nonempty() {
  local f="$1"
  require_file "$f"
  local sz
  sz="$(stat -c%s "$f")"
  [[ "$sz" -gt 0 ]] || { echo "ERROR: empty file $f" >&2; exit 1; }
}

# Run a PE via real Windows (WSL interop). Not Wine.
# Usage: run_windows_exe <exe_path> <workdir_on_windows_fs> [env assignments...]
run_windows_exe() {
  local exe="$1"
  local wdir="$2"
  shift 2
  require_file "$exe"
  [[ -x /mnt/c/Windows/System32/cmd.exe ]] \
    || { echo "ERROR: Windows interop missing (/mnt/c/Windows/System32/cmd.exe)" >&2; exit 1; }
  command -v wine >/dev/null 2>&1 && [[ "${LWPB_ALLOW_WINE:-}" != "1" ]] \
    && echo "NOTE: wine present but unused (Phase 5 forbids Wine)" >&2 || true

  mkdir -p "$wdir"
  local base
  base="$(basename "$exe")"
  cp -f "$exe" "${wdir}/${base}"

  # Convert WSL path to Windows path for cmd
  local win_dir
  win_dir="$(wslpath -w "$wdir")"

  local env_prefix=""
  local e
  for e in "$@"; do
    env_prefix+="set ${e}&& "
  done

  local out_log="${wdir}/run-stdout.txt"
  local err_log="${wdir}/run-stderr.txt"
  rm -f "$out_log" "$err_log"

  set +e
  /mnt/c/Windows/System32/cmd.exe /c \
    "cd /d ${win_dir} && ${env_prefix}${base} > run-stdout.txt 2> run-stderr.txt"
  local rc=$?
  set -e

  echo "windows_exit_code=${rc}"
  if [[ -f "$out_log" ]]; then
    echo "windows_stdout:"
    cat "$out_log"
  fi
  if [[ -f "$err_log" ]] && [[ -s "$err_log" ]]; then
    echo "windows_stderr:"
    cat "$err_log"
  fi
  return "$rc"
}

docker_clang() {
  # Run command inside pinned toolchain image with repo mounted.
  docker run --rm --user root \
    -v "${ROOT}:/src" \
    -w /src \
    "$IMG" \
    bash -lc "export PATH=/root/.mozbuild/clang/bin:\$PATH; $*"
}
