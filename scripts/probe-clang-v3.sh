#!/usr/bin/env bash
# Prove pinned Clang accepts -march=x86-64-v3 for x86_64-pc-windows-msvc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${ROOT}/artifacts/probes}"
TARGET="${LWPB_WINDOWS_TARGET_X64:-x86_64-pc-windows-msvc}"
FLAG="-march=x86-64-v3"

mkdir -p "$OUT_DIR"
REPORT="${OUT_DIR}/clang-v3-probe.txt"
: >"$REPORT"

if [[ -x /root/.mozbuild/clang/bin/clang ]]; then
  export PATH="/root/.mozbuild/clang/bin:${PATH}"
fi

CLANG="$(command -v clang || true)"
[[ -n "$CLANG" ]] || { echo "ERROR: clang not found" | tee -a "$REPORT" >&2; exit 1; }

{
  echo "clang_path=$CLANG"
  "$CLANG" --version | head -3
  echo "target=$TARGET"
  echo "flag_tested=$FLAG"
} | tee -a "$REPORT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/probe.c" <<'C'
int add(int a, int b) { return a + b; }
C
cat >"$TMP/probe.cpp" <<'CXX'
int add(int a, int b) { return a + b; }
CXX

set +e
"$CLANG" --target="$TARGET" "$FLAG" -c "$TMP/probe.c" -o "$TMP/probe.o" 2>"$TMP/c.err"
CRC=$?
"${CLANG}++" --target="$TARGET" "$FLAG" -c "$TMP/probe.cpp" -o "$TMP/probe.o" 2>"$TMP/cxx.err"
CXRC=$?
set -e

{
  echo "clang_c_exit=$CRC"
  echo "clang_cxx_exit=$CXRC"
  if [[ "$CRC" -eq 0 ]]; then
    echo "effective_target_cpu:"
    "$CLANG" --target="$TARGET" "$FLAG" -c "$TMP/probe.c" -o "$TMP/probe2.o" -### 2>&1 \
      | tr ' ' '\n' | grep -E 'target-cpu|x86-64-v3|march' || true
  else
    echo "clang_c_stderr:"
    cat "$TMP/c.err"
  fi
  if [[ "$CXRC" -ne 0 ]]; then
    echo "clang_cxx_stderr:"
    cat "$TMP/cxx.err"
  fi
} | tee -a "$REPORT"

if [[ "$CRC" -ne 0 || "$CXRC" -ne 0 ]]; then
  echo "CLANG_V3_PROBE=FAIL" | tee -a "$REPORT" >&2
  exit 1
fi
echo "CLANG_V3_PROBE=PASS" | tee -a "$REPORT"
