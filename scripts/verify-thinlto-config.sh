#!/usr/bin/env bash
# Verify Phase 4 ThinLTO + v3 composition (baseline empty, v3+thin frags OK).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${ROOT}/configs/mozconfig.baseline.frag"
V3="${ROOT}/configs/mozconfig.x86-64-v3.frag"
THIN="${ROOT}/configs/mozconfig.thinlto.frag"
CONTRACT="${ROOT}/configs/phase4-thinlto.contract.json"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$BASE" && -f "$V3" && -f "$THIN" && -f "$CONTRACT" ]] || die "missing Phase 4 config files"

CONTENT="$(grep -vE '^\s*(#|$)' "$BASE" || true)"
[[ -z "$CONTENT" ]] || die "Phase 2 baseline frag must remain empty"

grep -q 'LWPB_PHASE3_X86_64_V3' "$V3" || die "v3 frag missing marker"
grep -Eq -- '-march=x86-64-v3' "$V3" || die "v3 frag missing -march"
grep -Eq -- 'target-cpu=x86-64-v3' "$V3" || die "v3 frag missing rust target-cpu"

grep -q 'LWPB_PHASE4_THINLTO' "$THIN" || die "thinlto frag missing marker"
ACTIVE="$(grep -vE '^\s*(#|$)' "$THIN" || true)"
echo "$ACTIVE" | grep -Eq -- '--enable-lto=thin' || die "thinlto frag must enable --enable-lto=thin"
if echo "$ACTIVE" | grep -Eq 'full|,cross|cross,|enable-lto=full'; then
  die "thinlto frag must not enable full or cross LTO"
fi
if echo "$ACTIVE" | grep -Eq 'csir|cs-profile|MOZ_PGO|profile-generate'; then
  die "thinlto frag must not enable PGO/CSIR"
fi

# bsys6 LTO env must not be used for Phase 4 (would inject full,cross)
if [[ -n "${LTO:-}" && "${LTO}" != "false" && "${LTO}" != "0" ]]; then
  die "Phase 4 forbids LTO env=${LTO} (use mozconfig --enable-lto=thin only)"
fi

jq -e '
  .requested.overlay_lto_mode == "thin"
  and .requested.full_lto == false
  and .requested.cross_language_lto == false
  and .requested.upstream_pgo == true
  and .requested.upstream_rust_lto == true
  and .requested.csir == false
  and .cpu_baseline == "x86-64-v3"
' "$CONTRACT" >/dev/null || die "phase4 contract invalid"

echo "Phase 4 ThinLTO config OK"
