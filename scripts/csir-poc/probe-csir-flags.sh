#!/usr/bin/env bash
# Probe pinned Clang CSIR flag semantics for x86_64-pc-windows-msvc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-poc/common.sh"

OUT_JSON="${ART}/meta/toolchain.json"
mkdir -p "${ART}/meta"

docker run --rm --user root -v "${ROOT}:/src" -w /tmp "$IMG" bash -lc '
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:$PATH
CLANG_V=$(clang --version | head -1)
LLD_V=$(lld-link --version 2>&1 | head -1)
PROF_V=$(llvm-profdata --version 2>&1 | head -1)
echo "int foo(int x){return x+1;} int main(){return foo(1);}" > /tmp/t.c
set +e
clang-cl -fms-compatibility-version=19.50 --target=x86_64-pc-windows-msvc \
  -fprofile-generate -fcs-profile-generate -c /tmp/t.c -Fo/tmp/both.obj 2>/tmp/both.err
BOTH=$?
clang-cl -fms-compatibility-version=19.50 --target=x86_64-pc-windows-msvc \
  -fcs-profile-generate -c /tmp/t.c -Fo/tmp/cs.obj 2>/tmp/cs.err
CS=$?
clang-cl -fms-compatibility-version=19.50 --target=x86_64-pc-windows-msvc \
  -fprofile-generate -c /tmp/t.c -Fo/tmp/ir.obj 2>/tmp/ir.err
IR=$?
set -e
BOTH_MSG=$(tr "\n" " " </tmp/both.err)
CS_OK=false; [[ $CS -eq 0 ]] && CS_OK=true
IR_OK=false; [[ $IR -eq 0 ]] && IR_OK=true
COEXIST=rejected
[[ $BOTH -eq 0 ]] && COEXIST=supported
cat > /src/artifacts/csir-poc/meta/toolchain.json <<EOF
{
  "clang": "$CLANG_V",
  "linker": "$LLD_V",
  "llvm_profdata": "$PROF_V",
  "target": "x86_64-pc-windows-msvc",
  "custom_llvm_required": false,
  "flags": {
    "fprofile_generate_alone": $IR_OK,
    "fcs_profile_generate_alone": $CS_OK,
    "fprofile_generate_plus_fcs_same_compile": "$COEXIST",
    "coexistence_diagnostic": $(printf "%s" "$BOTH_MSG" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
  },
  "help": {
    "fcs_profile_generate": "Generate instrumented code to collect context sensitive execution counts",
    "fcs_profile_generate_eq": "directory form supported"
  }
}
EOF
'

jq -e '.flags.fcs_profile_generate_alone == true
  and .flags.fprofile_generate_alone == true
  and .flags.fprofile_generate_plus_fcs_same_compile == "rejected"' "$OUT_JSON" >/dev/null

echo "Wrote $OUT_JSON"
jq . "$OUT_JSON"
