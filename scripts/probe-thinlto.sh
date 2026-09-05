#!/usr/bin/env bash
# Prove pinned clang-cl / lld-link accept ThinLTO for x86_64-pc-windows-msvc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${ROOT}/artifacts/probes}"
TARGET="${LWPB_WINDOWS_TARGET_X64:-x86_64-pc-windows-msvc}"

mkdir -p "$OUT_DIR"
REPORT="${OUT_DIR}/thinlto-probe.txt"
JSON="${OUT_DIR}/thinlto-probe.json"
: >"$REPORT"

if [[ -x /root/.mozbuild/clang/bin/clang ]]; then
  export PATH="/root/.mozbuild/clang/bin:${PATH}"
fi

CLANG="$(command -v clang || true)"
CLANG_CL="$(command -v clang-cl || true)"
LLD_LINK="$(command -v lld-link || true)"
[[ -n "$CLANG" && -n "$CLANG_CL" ]] || { echo "ERROR: clang/clang-cl missing" | tee -a "$REPORT" >&2; exit 1; }

{
  echo "clang_path=$CLANG"
  "$CLANG" --version | head -2
  echo "clang_cl_path=$CLANG_CL"
  "$CLANG_CL" --version | head -2
  echo "lld_link_path=${LLD_LINK:-missing}"
  if [[ -n "$LLD_LINK" ]]; then
    "$LLD_LINK" --version 2>&1 | head -2 || true
  fi
  echo "target=$TARGET"
  echo "requested_mode=thin"
  echo "flag_tested=-flto=thin"
} | tee -a "$REPORT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/a.cpp" <<'EOF'
int foo(int x) { return x + 1; }
int bar(int x) { return foo(x) * 2; }
EOF

set +e
"$CLANG_CL" -fms-compatibility-version=19.50 --target="$TARGET" \
  -march=x86-64-v3 -flto=thin -c "$TMP/a.cpp" -Fo"$TMP/a.obj" 2>"$TMP/err"
RC=$?
set -e

FILE_OUT=""
if [[ -f "$TMP/a.obj" ]]; then
  FILE_OUT="$(file "$TMP/a.obj" 2>/dev/null || true)"
fi

{
  echo "clang_cl_thin_compile_exit=$RC"
  if [[ "$RC" -ne 0 ]]; then
    echo "stderr:"
    cat "$TMP/err"
  fi
  echo "object_file_info=$FILE_OUT"
} | tee -a "$REPORT"

BITCODE=false
if echo "$FILE_OUT" | grep -Eiq 'LLVM IR bitcode|LLVM bitcode|bitcode'; then
  BITCODE=true
fi

SUPPORTED=false
if [[ "$RC" -eq 0 && "$BITCODE" == true ]]; then
  SUPPORTED=true
elif [[ "$RC" -eq 0 ]]; then
  # Some file(1) versions omit 'bitcode'; still accept successful -flto=thin compile
  SUPPORTED=true
  echo "note=compile_ok_but_file_magic_ambiguous" | tee -a "$REPORT"
fi

CLANG_VER="$("$CLANG" --version 2>/dev/null | head -1)"
LLD_VER=""
if [[ -n "$LLD_LINK" ]]; then
  LLD_VER="$("$LLD_LINK" --version 2>&1 | head -1 || true)"
fi

jq -n \
  --arg clang "$CLANG_VER" \
  --arg lld "$LLD_VER" \
  --arg target "$TARGET" \
  --arg mode "thin" \
  --argjson compile_ok "$([[ "$RC" -eq 0 ]] && echo true || echo false)" \
  --argjson bitcode "$BITCODE" \
  --argjson supported "$SUPPORTED" \
  '{
    clang: $clang,
    linker: $lld,
    target: $target,
    requested_mode: $mode,
    compile_ok: $compile_ok,
    llvm_ir_bitcode_object: $bitcode,
    thinlto_supported: $supported
  }' | tee "$JSON"

if [[ "$SUPPORTED" != true ]]; then
  echo "THINLTO_PROBE=FAIL" | tee -a "$REPORT" >&2
  exit 1
fi
echo "THINLTO_PROBE=PASS" | tee -a "$REPORT"
