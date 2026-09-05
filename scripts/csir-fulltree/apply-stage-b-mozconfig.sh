#!/usr/bin/env bash
# Apply Stage B mozconfig: base.profdata use + CSIR generate overlay (C/C++ only).
# Usage: apply-stage-b-mozconfig.sh <mozconfig.backup> <base.profdata> <cs_gen_dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

BACKUP="${1:?mozconfig.backup}"
BASE_PROF="${2:?base.profdata}"
CS_GEN_DIR="${3:?cs_gen_dir}"

require_file "$BACKUP"
require_nonempty "$BASE_PROF"
mkdir -p "$CS_GEN_DIR"
BASE_ABS="$(cd "$(dirname "$BASE_PROF")" && pwd)/$(basename "$BASE_PROF")"
CS_ABS="$(cd "$CS_GEN_DIR" && pwd)"

strip_upstream_profdata_use "$BACKUP"
# Remove prior Phase 6 stage markers that conflict
tmp="$(mktemp)"
grep -Ev 'LWPB_PHASE6_CSIR_BASE_GEN|LWPB_PHASE6_CSIR_CS_GEN|LWPB_PHASE6_CSIR_FINAL|--enable-profile-generate|--enable-lto' \
  "$BACKUP" >"$tmp" || true
mv "$tmp" "$BACKUP"

{
  echo ""
  cat "${ROOT}/configs/mozconfig.csir-cs-gen.frag"
  echo "ac_add_options --enable-profile-use"
  echo "ac_add_options --with-pgo-profile-path=${BASE_ABS}"
  # clang-cl needs /clang: prefix (SOURCE-SUPPORTED via lto-pgo.configure)
  echo "export CFLAGS=\"\${CFLAGS:+\${CFLAGS} }/clang:-fcs-profile-generate=${CS_ABS}\""
  echo "export CXXFLAGS=\"\${CXXFLAGS:+\${CXXFLAGS} }/clang:-fcs-profile-generate=${CS_ABS}\""
} >>"$BACKUP"

echo "Stage B mozconfig.backup prepared: use=${BASE_ABS} cs-gen=${CS_ABS}"
