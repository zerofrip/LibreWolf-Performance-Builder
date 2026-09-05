#!/usr/bin/env bash
# Lightweight Stage C probe: clang-cl accepts -fprofile-use=<combined.profdata>
# Optionally also -flto=thin -march=x86-64-v3. NOT a Stage D proof.
# Usage: probe-combined-profile.sh <combined.profdata>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

COMBINED="${1:?combined.profdata}"
[[ "$COMBINED" = /* ]] || COMBINED="${ROOT}/${COMBINED}"
require_nonempty "$COMBINED"
COMB_REL="${COMBINED#"$ROOT"/}"
[[ "$COMB_REL" != "$COMBINED" ]] || { echo "ERROR: combined must be under ROOT" >&2; exit 1; }
META_REL="${META_DIR#"$ROOT"/}"
mkdir -p "${META_DIR}/stage-c-probe"

cat >"${META_DIR}/stage-c-probe/probe.c" <<'EOF'
int probe(int x) { return x * 2 + 1; }
int main(void) { return probe(3) == 7 ? 0 : 1; }
EOF

docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
VS=/root/.mozbuild/win-cross/vs
MSVC=\"\${VS}/VC/Tools/MSVC/14.50.35717\"
SDKVER=10.0.26100.0
SDK=\"\${VS}/Windows Kits/10\"
TARGET=x86_64-pc-windows-msvc
clang --version | head -1 | tee /src/${META_REL}/stage-c-probe/clang-version.txt
OUT=/src/${META_REL}/stage-c-probe
SRC=/src/${META_REL}/stage-c-probe/probe.c
PROF=/src/${COMB_REL}

# Probe 1: profile-use only
set +e
clang-cl -fms-compatibility-version=19.50 --target=\$TARGET \
  -imsvc \"\${MSVC}/include\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/ucrt\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/um\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/shared\" \
  /c /Fo\${OUT}/probe-use.obj \
  /clang:-fprofile-use=\${PROF} \
  \$SRC >\${OUT}/probe-use.log 2>&1
ec1=\$?
set -e
echo \"profile_use_exit=\$ec1\" | tee -a \${OUT}/summary.txt
tail -20 \${OUT}/probe-use.log | tee -a \${OUT}/summary.txt

# Probe 2: profile-use + ThinLTO + x86-64-v3
set +e
clang-cl -fms-compatibility-version=19.50 --target=\$TARGET \
  -imsvc \"\${MSVC}/include\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/ucrt\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/um\" \
  -imsvc \"\${SDK}/Include/\${SDKVER}/shared\" \
  /c /Fo\${OUT}/probe-v3-thin.obj \
  -march=x86-64-v3 \
  /clang:-flto=thin \
  /clang:-fprofile-use=\${PROF} \
  \$SRC >\${OUT}/probe-v3-thin.log 2>&1
ec2=\$?
set -e
echo \"v3_thin_profile_use_exit=\$ec2\" | tee -a \${OUT}/summary.txt
tail -20 \${OUT}/probe-v3-thin.log | tee -a \${OUT}/summary.txt
[[ \$ec1 -eq 0 && \$ec2 -eq 0 ]]
"

echo "Stage C lightweight probes PASS (parse/acceptance only; not Stage D)"
