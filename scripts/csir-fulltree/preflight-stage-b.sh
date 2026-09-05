#!/usr/bin/env bash
# Lightweight Stage B preflight: compile a tiny Windows-target TU with
# -fprofile-use=<LibreWolf base.profdata> -fcs-profile-generate=<dir>
# Usage: preflight-stage-b.sh <base.profdata>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

BASE="${1:?base.profdata}"
require_nonempty "$BASE"
mkdir -p "${META_DIR}/preflight" "${PROF_DIR}/preflight-cs"

BASE_REL="${BASE#"$ROOT"/}"
[[ "$BASE_REL" != "$BASE" ]] || { echo "ERROR: base must be under $ROOT" >&2; exit 1; }

# Minimal C source (not LibreWolf) — only checks compiler/profile acceptance
cat >"${META_DIR}/preflight/probe.c" <<'EOF'
int probe(int x) { return x * 2 + 1; }
int main(void) { return probe(3) == 7 ? 0 : 1; }
EOF

LOG="${META_DIR}/preflight/compile.log"
set +e
docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
VS=/root/.mozbuild/win-cross/vs
MSVC=\${VS}/VC/Tools/MSVC/14.50.35717
SDKVER=10.0.26100.0
SDK=\${VS}/Windows\ Kits/10
TARGET=x86_64-pc-windows-msvc
mkdir -p /src/${PROF_DIR#"$ROOT"/}/preflight-cs
clang-cl -fms-compatibility-version=19.50 --target=\$TARGET \
  -imsvc \"\${MSVC}/include\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/ucrt\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/shared\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/um\" \
  -O2 /Ob0 \
  -fprofile-use=/src/${BASE_REL} \
  -fcs-profile-generate=/src/${PROF_DIR#"$ROOT"/}/preflight-cs \
  /src/${META_DIR#"$ROOT"/}/preflight/probe.c \
  -c -Fo/src/${META_DIR#"$ROOT"/}/preflight/probe.obj
" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

if grep -Eiq 'malformed instrumentation profile|no profile data available' "$LOG"; then
  echo "ERROR: preflight rejected base.profdata" >&2
  exit 1
fi
if grep -Eiq 'function control flow change detected|hash mismatch' "$LOG"; then
  echo "WARN: CFG/hash diagnostics on unrelated probe TU (expected for non-matching source)" | tee -a "$LOG"
  # Unrelated TU will not match LibreWolf CFG — do not treat as fatal for preflight of
  # 'compiler accepts flags + can open profile'. Material mismatch is a Stage B full-tree gate.
fi
[[ "$RC" -eq 0 ]] || { echo "ERROR: preflight compile failed rc=$RC" >&2; exit 1; }

write_stage_meta "${META_DIR}/preflight-stage-b.json" \
  --arg base "$BASE" \
  --arg sha "$(json_sha256 "$BASE")" \
  --argjson compile_ok true \
  '{stage:"B-preflight",base:$base,base_sha256:$sha,compile_ok:$compile_ok,note:"probe TU; full-tree mismatch gated in Stage B"}'

echo "Stage B preflight PASS (compiler accepted -fprofile-use + -fcs-profile-generate)"
