#!/usr/bin/env bash
# Shared helpers for Phase 6 full-tree CSIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

ART="${ROOT}/artifacts/csir-fulltree"
RUN_ID="${LWPB_CSIR_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${ART}/runs/${RUN_ID}"
PROF_DIR="${RUN_DIR}/profiles"
META_DIR="${RUN_DIR}/meta"
OUT_DIR="${RUN_DIR}/out"
WIN_TRAIN_ROOT="${LWPB_CSIR_WIN_ROOT:-/mnt/c/Users/Public/lwpb-csir-fulltree}"
IMG="${LWPB_BSYS6_IMAGE:-codeberg.org/librewolf/bsys6:windows}"
PROFDATA_DISABLED_NAME="windows.profdata.lwpb-phase6-disabled"

mkdir -p "$ART" "$RUN_DIR" "$PROF_DIR" "$META_DIR" "$OUT_DIR"

json_sha256() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return 0; }
  sha256sum "$f" | awk '{print $1}'
}

require_file() {
  [[ -f "$1" ]] || { echo "ERROR: missing $1" >&2; exit 1; }
}

require_nonempty() {
  require_file "$1"
  local sz
  sz="$(stat -c%s "$1")"
  [[ "$sz" -gt 0 ]] || { echo "ERROR: empty $1" >&2; exit 1; }
}

# Remove profile-use / pgo-profile-path lines (Stage A: no profile-use allowed).
strip_upstream_profdata_use() {
  local mc="$1"
  require_file "$mc"
  local tmp
  tmp="$(mktemp)"
  grep -Ev -- '--enable-profile-use|--with-pgo-profile-path=' "$mc" >"$tmp" || true
  mv "$tmp" "$mc"
}

# Remove only upstream windows.profdata references (keep Stage B/D profile-use).
strip_windows_profdata_lines() {
  local mc="$1"
  require_file "$mc"
  local tmp
  tmp="$(mktemp)"
  grep -Ev -- 'windows\.profdata' "$mc" >"$tmp" || true
  mv "$tmp" "$mc"
}

# bsys6 source.sh ALWAYS re-appends assets/windows.profdata when the file exists.
# Hide the asset so Stage A/B/D can set an unambiguous profile authority.
disable_upstream_profdata_asset() {
  local bsys6_dir="${1:-${LWPB_BSYS6_DIR:?LWPB_BSYS6_DIR required}}"
  local src="${bsys6_dir}/assets/windows.profdata"
  local dst="${bsys6_dir}/assets/${PROFDATA_DISABLED_NAME}"
  if [[ -f "$src" ]]; then
    mv -f "$src" "$dst"
    echo "-> Disabled upstream profile asset: $src -> $dst"
  elif [[ -f "$dst" ]]; then
    echo "-> Upstream profile asset already disabled: $dst"
  else
    echo "NOTE: no windows.profdata asset found under ${bsys6_dir}/assets" >&2
  fi
  [[ ! -f "$src" ]] || { echo "ERROR: failed to disable $src" >&2; exit 1; }
}

restore_upstream_profdata_asset() {
  local bsys6_dir="${1:-${LWPB_BSYS6_DIR:?}}"
  local src="${bsys6_dir}/assets/${PROFDATA_DISABLED_NAME}"
  local dst="${bsys6_dir}/assets/windows.profdata"
  if [[ -f "$src" && ! -f "$dst" ]]; then
    mv -f "$src" "$dst"
    echo "-> Restored upstream profile asset: $dst"
  fi
}

append_frag() {
  local mc="$1"
  local frag="$2"
  local marker="$3"
  if ! grep -q "$marker" "$mc"; then
    {
      echo ""
      cat "$frag"
    } >>"$mc"
  fi
}

# Regenerate mozconfig from backup after edits.
# With windows.profdata asset disabled, bsys6 will not re-inject upstream PGO.
# Still drop any residual windows.profdata lines (never strip intentional profile-use).
regenerate_mozconfig() {
  local bsys6_dir="${1:?}"
  local mozconfig="${2:?}"
  rm -f "${mozconfig}.hash"
  (
    cd "$bsys6_dir"
    ./bsys6 source
  )
  strip_windows_profdata_lines "$mozconfig"
  if grep -Eq -- 'windows\.profdata' "$mozconfig"; then
    echo "ERROR: windows.profdata still present after regenerate" >&2
    exit 1
  fi
  sha256sum "$mozconfig" | awk '{print $1}' >"${mozconfig}.hash"
}

require_windows_interop() {
  [[ -x /mnt/c/Windows/System32/cmd.exe ]] \
    || { echo "ERROR: Windows interop missing" >&2; exit 1; }
  if command -v wine >/dev/null 2>&1 && [[ "${LWPB_ALLOW_WINE:-}" != "1" ]]; then
    echo "NOTE: wine present but unused (Phase 6 forbids Wine for authority)" >&2
  fi
}

write_stage_meta() {
  local out="$1"
  shift
  jq -n "$@" >"$out"
  echo "Wrote $out"
}

# Run llvm-profdata inside pinned bsys6:windows image (Clang/LLVM 21.1.8).
docker_llvm_profdata() {
  docker run --rm --user root \
    -v "${ROOT}:/src" \
    -w /src \
    "$IMG" \
    bash -lc "export PATH=/root/.mozbuild/clang/bin:\$PATH; llvm-profdata $*"
}
