#!/usr/bin/env bash
# Merge Stage B CS *.profraw -> cs.profdata, then base+cs -> combined.profdata.
# Usage: merge-combined.sh [cs_raw_dir] [base.profdata] [out_dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

CS_RAW_DIR="${1:-${PROF_DIR}/stage-b-raw}"
BASE="${2:-${PROF_DIR}/base.profdata}"
OUT_DIR_LOCAL="${3:-${PROF_DIR}}"
CS_OUT="${OUT_DIR_LOCAL}/cs.profdata"
COMBINED="${OUT_DIR_LOCAL}/combined.profdata"
mkdir -p "$OUT_DIR_LOCAL" "$META_DIR"

require_nonempty "$BASE"
mapfile -t RAWS < <(find "$CS_RAW_DIR" -type f -name '*.profraw' | sort)
[[ "${#RAWS[@]}" -gt 0 ]] || { echo "ERROR: no CS profraw in $CS_RAW_DIR" >&2; exit 1; }

REL_RAWS=()
for f in "${RAWS[@]}"; do
  rel="${f#"$ROOT"/}"
  [[ "$rel" != "$f" ]] || { echo "ERROR: $f not under $ROOT" >&2; exit 1; }
  REL_RAWS+=("$rel")
done
BASE_REL="${BASE#"$ROOT"/}"
CS_REL="${CS_OUT#"$ROOT"/}"
COMB_REL="${COMBINED#"$ROOT"/}"
META_REL="${META_DIR#"$ROOT"/}"

docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
llvm-profdata --version | head -1 | tee /src/${META_REL}/llvm-profdata-version-stage-c.txt
llvm-profdata merge -output=/src/${CS_REL} $(printf '/src/%s ' "${REL_RAWS[@]}")
llvm-profdata show --showcs --all-functions /src/${CS_REL} > /src/${META_REL}/cs-profdata-showcs.txt
llvm-profdata show /src/${CS_REL} > /src/${META_REL}/cs-profdata-show.txt
llvm-profdata merge -output=/src/${COMB_REL} /src/${BASE_REL} /src/${CS_REL}
llvm-profdata show --all-functions /src/${COMB_REL} > /src/${META_REL}/combined-profdata-show.txt
llvm-profdata show --showcs --all-functions /src/${COMB_REL} > /src/${META_REL}/combined-profdata-showcs.txt
llvm-profdata show /src/${COMB_REL} > /src/${META_REL}/combined-profdata-summary.txt
"

require_nonempty "$CS_OUT"
require_nonempty "$COMBINED"

# CS records must be present (Phase 5: without --showcs Total functions can be 0)
CS_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/cs-profdata-showcs.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
NOCS_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/cs-profdata-show.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
if [[ "${CS_FUNCS:-0}" -le 0 ]]; then
  echo "ERROR: CS profile has no functions under --showcs" >&2
  head -40 "${META_DIR}/cs-profdata-showcs.txt" >&2
  exit 1
fi

COMB_SHA="$(json_sha256 "$COMBINED")"
CS_SHA="$(json_sha256 "$CS_OUT")"
BASE_SHA="$(json_sha256 "$BASE")"

write_stage_meta "${META_DIR}/combined-profdata.json" \
  --arg base "$BASE" --arg base_sha "$BASE_SHA" \
  --arg cs "$CS_OUT" --arg cs_sha "$CS_SHA" \
  --arg combined "$COMBINED" --arg combined_sha "$COMB_SHA" \
  --argjson cs_funcs_showcs "${CS_FUNCS}" \
  --argjson cs_funcs_noshowcs "${NOCS_FUNCS:-0}" \
  --argjson combined_size "$(stat -c%s "$COMBINED")" \
  '{stage:"C",base:$base,base_sha256:$base_sha,cs:$cs,cs_sha256:$cs_sha,combined:$combined,combined_sha256:$combined_sha,cs_funcs_showcs:$cs_funcs_showcs,cs_funcs_without_showcs:$cs_funcs_noshowcs,combined_bytes:$combined_size}'

echo "combined.profdata OK sha256=$COMB_SHA cs_funcs_showcs=$CS_FUNCS"
