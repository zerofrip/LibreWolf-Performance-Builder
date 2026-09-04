#!/usr/bin/env bash
# Prove pinned rustc accepts -C target-cpu=x86-64-v3 for x86_64-pc-windows-msvc.
# If unsupported: exit non-zero — human gate (do not invent target-feature lists).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${ROOT}/artifacts/probes}"
TARGET="${LWPB_WINDOWS_TARGET_X64:-x86_64-pc-windows-msvc}"
CANDIDATE="x86-64-v3"
FLAG="-C target-cpu=${CANDIDATE}"

mkdir -p "$OUT_DIR"
REPORT="${OUT_DIR}/rust-v3-probe.txt"
JSON="${OUT_DIR}/rust-v3-probe.json"
: >"$REPORT"

if [[ -x /root/.cargo/bin/rustc ]]; then
  export PATH="/root/.cargo/bin:${PATH}"
fi

RUSTC="$(command -v rustc || true)"
[[ -n "$RUSTC" ]] || { echo "ERROR: rustc not found" | tee -a "$REPORT" >&2; exit 1; }

VER="$("$RUSTC" --version)"
{
  echo "rustc_path=$RUSTC"
  echo "rustc_version=$VER"
  echo "target=$TARGET"
  echo "candidate=$CANDIDATE"
  echo "flag_tested=$FLAG"
} | tee -a "$REPORT"

CPUS="$("$RUSTC" --print target-cpus --target "$TARGET" 2>&1 || true)"
echo "$CPUS" >"${OUT_DIR}/rust-target-cpus.txt"

if echo "$CPUS" | grep -Eq "^[[:space:]]*${CANDIDATE}([[:space:]]|$)"; then
  LISTED=true
  echo "target_cpu_listed=true" | tee -a "$REPORT"
else
  LISTED=false
  echo "target_cpu_listed=false" | tee -a "$REPORT"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/probe.rs" <<'RS'
#![crate_type = "rlib"]
pub fn add(a: u32, b: u32) -> u32 {
    a.wrapping_add(b)
}
RS

set +e
"$RUSTC" --target "$TARGET" $FLAG -O -o "$TMP/probe.rlib" "$TMP/probe.rs" 2>"$TMP/err.txt"
RC=$?
set -e

{
  echo "rustc_compile_exit=$RC"
  if [[ "$RC" -ne 0 ]]; then
    echo "rustc_stderr:"
    cat "$TMP/err.txt"
  fi
} | tee -a "$REPORT"

SUPPORTED=false
if [[ "$LISTED" == true && "$RC" -eq 0 ]]; then
  SUPPORTED=true
fi

jq -n \
  --arg ver "$VER" \
  --arg target "$TARGET" \
  --arg candidate "$CANDIDATE" \
  --argjson listed "$LISTED" \
  --argjson compile_ok "$([[ "$RC" -eq 0 ]] && echo true || echo false)" \
  --argjson supported "$SUPPORTED" \
  '{
    rustc: $ver,
    target: $target,
    candidate: $candidate,
    target_cpu_listed: $listed,
    compile_ok: $compile_ok,
    direct_target_cpu_supported: $supported
  }' | tee "$JSON"

if [[ "$SUPPORTED" != true ]]; then
  {
    echo "RUST_V3_DIRECT_TARGET=UNSUPPORTED"
    echo "RUST_V3=BLOCKED"
    echo "REASON: pinned rustc does not accept direct -C target-cpu=${CANDIDATE} for ${TARGET}"
    echo "Do NOT invent -C target-feature=... or use target-cpu=native."
    echo "SUPPORTED TARGET-CPU OPTIONS (excerpt):"
    echo "$CPUS" | grep -E 'x86-64|generic|native' || true
  } | tee -a "$REPORT" >&2
  exit 1
fi

echo "RUST_V3_DIRECT_TARGET=SUPPORTED" | tee -a "$REPORT"
echo "RUST_V3_PROBE=PASS" | tee -a "$REPORT"
