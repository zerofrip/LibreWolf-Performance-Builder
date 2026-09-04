#!/usr/bin/env bash
# Verify Phase 3 v3 fragment is present and baseline fragment stays empty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${ROOT}/configs/mozconfig.baseline.frag"
V3="${ROOT}/configs/mozconfig.x86-64-v3.frag"
CONTRACT="${ROOT}/configs/phase3-x86-64-v3.contract.json"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$BASE" ]] || die "missing $BASE"
[[ -f "$V3" ]] || die "missing $V3"
[[ -f "$CONTRACT" ]] || die "missing $CONTRACT"

CONTENT="$(grep -vE '^\s*(#|$)' "$BASE" || true)"
[[ -z "$CONTENT" ]] || die "Phase 2 baseline frag must remain empty of active lines"

grep -q 'LWPB_PHASE3_X86_64_V3' "$V3" || die "v3 frag missing marker"
grep -Eq -- '-march=x86-64-v3' "$V3" || die "v3 frag missing -march=x86-64-v3"
grep -Eq -- 'target-cpu=x86-64-v3' "$V3" || die "v3 frag missing target-cpu=x86-64-v3"
# Forbid host leakage knobs and forbidden ISAs on active lines only
ACTIVE="$(grep -vE '^\s*(#|$)' "$V3" || true)"
if echo "$ACTIVE" | grep -Eq 'HOST_CFLAGS|HOST_CXXFLAGS|target-cpu=native|-march=native|x86-64-v4|mcpu=native'; then
  die "v3 frag contains forbidden host/native/v4 flags"
fi
if echo "$ACTIVE" | grep -Eq 'enable-lto|MOZ_PGO|cs-profile|csir'; then
  die "v3 frag must not enable LTO/PGO/CSIR"
fi

jq -e '
  .cpu_baseline == "x86-64-v3"
  and .target_triple == "x86_64-pc-windows-msvc"
  and .requested.rust_x86_64_v3 == true
  and .requested.c_x86_64_v3 == true
  and .requested.upstream_pgo == true
  and .requested.csir == false
  and .host_specific_tuning == false
' "$CONTRACT" >/dev/null || die "phase3 contract JSON invalid"

# Phase 3 must not enable overlay LTO/PGO via env
if [[ -n "${LTO:-}" && "${LTO}" != "false" && "${LTO}" != "0" ]]; then
  die "Phase 3 forbids LTO env=${LTO}"
fi

echo "Phase 3 v3 config OK"
