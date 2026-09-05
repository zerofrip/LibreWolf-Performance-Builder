#!/usr/bin/env bash
# Stage C ONLY: merge authoritative base.profdata + cs.profdata -> combined.profdata.
# Does NOT rebuild CS from raw. Does NOT start Stage D.
# Usage: merge-stage-c.sh [base.profdata] [cs.profdata] [combined.profdata]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

BASE="${1:-${PROF_DIR}/base.profdata}"
CS="${2:-${PROF_DIR}/cs.profdata}"
COMBINED="${3:-${PROF_DIR}/combined.profdata}"

BASE="$(cd "$(dirname "$BASE")" && pwd)/$(basename "$BASE")"
CS="$(cd "$(dirname "$CS")" && pwd)/$(basename "$CS")"
mkdir -p "$(dirname "$COMBINED")" "$META_DIR"
COMBINED="$(cd "$(dirname "$COMBINED")" && pwd)/$(basename "$COMBINED")"

require_nonempty "$BASE"
require_nonempty "$CS"

BASE_SHA="$(json_sha256 "$BASE")"
CS_SHA="$(json_sha256 "$CS")"
BASE_SIZE="$(stat -c%s "$BASE")"
CS_SIZE="$(stat -c%s "$CS")"

# Exact authority gates
[[ "$BASE_SHA" == "6b57dfaba67d480726cabb016bb4a64fface2cbe79e8181ef65182514f17099a" ]] \
  || { echo "ERROR: base.profdata SHA256 mismatch: $BASE_SHA" >&2; exit 1; }
[[ "$BASE_SIZE" == "114720872" ]] \
  || { echo "ERROR: base.profdata size mismatch: $BASE_SIZE" >&2; exit 1; }
[[ "$CS_SHA" == "068c1a158d6933974fa45365903f98ff6404b8700a6bd0f4ce858952744d5f7e" ]] \
  || { echo "ERROR: cs.profdata SHA256 mismatch: $CS_SHA" >&2; exit 1; }
[[ "$CS_SIZE" == "113442720" ]] \
  || { echo "ERROR: cs.profdata size mismatch: $CS_SIZE" >&2; exit 1; }

if [[ -e "$COMBINED" ]]; then
  echo "ERROR: combined.profdata already exists at $COMBINED — refuse silent overwrite" >&2
  exit 1
fi

BASE_REL="${BASE#"$ROOT"/}"
CS_REL="${CS#"$ROOT"/}"
COMB_REL="${COMBINED#"$ROOT"/}"
META_REL="${META_DIR#"$ROOT"/}"
[[ "$BASE_REL" != "$BASE" && "$CS_REL" != "$CS" && "$COMB_REL" != "$COMBINED" ]] \
  || { echo "ERROR: inputs/output must live under $ROOT" >&2; exit 1; }

MERGE_LOG="${META_DIR}/stage-c-merge.log"
: >"$MERGE_LOG"

{
  echo "COMMAND: llvm-profdata merge -output=/src/${COMB_REL} /src/${BASE_REL} /src/${CS_REL}"
  echo "BASE_SHA256=${BASE_SHA}"
  echo "CS_SHA256=${CS_SHA}"
} | tee -a "$MERGE_LOG"

docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
llvm-profdata --version | tee /src/${META_REL}/llvm-profdata-version-stage-c.txt
# Pre-merge input characterization
llvm-profdata show /src/${BASE_REL} > /src/${META_REL}/stage-c-base-show.txt
llvm-profdata show --showcs /src/${CS_REL} > /src/${META_REL}/stage-c-cs-showcs.txt
llvm-profdata show /src/${CS_REL} > /src/${META_REL}/stage-c-cs-show.txt
echo '== merge ==' | tee -a /src/${META_REL}/stage-c-merge.log
set +e
llvm-profdata merge -output=/src/${COMB_REL} /src/${BASE_REL} /src/${CS_REL} \
  > /src/${META_REL}/stage-c-merge.stdout 2> /src/${META_REL}/stage-c-merge.stderr
ec=\$?
set -e
echo \"exit=\$ec\" | tee -a /src/${META_REL}/stage-c-merge.log
cat /src/${META_REL}/stage-c-merge.stdout >> /src/${META_REL}/stage-c-merge.log || true
cat /src/${META_REL}/stage-c-merge.stderr >> /src/${META_REL}/stage-c-merge.log || true
[[ \$ec -eq 0 ]] || exit \$ec
llvm-profdata show /src/${COMB_REL} > /src/${META_REL}/combined-profdata-show.txt
llvm-profdata show --showcs /src/${COMB_REL} > /src/${META_REL}/combined-profdata-showcs.txt
llvm-profdata show --all-functions /src/${COMB_REL} > /src/${META_REL}/combined-profdata-show-all.txt
llvm-profdata show --showcs --all-functions /src/${COMB_REL} > /src/${META_REL}/combined-profdata-showcs-all.txt
"

require_nonempty "$COMBINED"
COMB_SHA="$(json_sha256 "$COMBINED")"
COMB_SIZE="$(stat -c%s "$COMBINED")"
COMB_TS="$(date -u -d "@$(stat -c %Y "$COMBINED")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

ORD_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/combined-profdata-show.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
CS_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/combined-profdata-showcs.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
if [[ "${ORD_FUNCS:-0}" -le 0 ]]; then
  echo "ERROR: ordinary view has zero functions after merge" >&2
  head -20 "${META_DIR}/combined-profdata-show.txt" >&2
  exit 1
fi
if [[ "${CS_FUNCS:-0}" -le 0 ]]; then
  echo "ERROR: --showcs view has zero functions after merge" >&2
  head -20 "${META_DIR}/combined-profdata-showcs.txt" >&2
  exit 1
fi

# Input immutability
BASE_SHA_AFTER="$(json_sha256 "$BASE")"
CS_SHA_AFTER="$(json_sha256 "$CS")"
[[ "$BASE_SHA_AFTER" == "$BASE_SHA" ]] || { echo "ERROR: base mutated" >&2; exit 1; }
[[ "$CS_SHA_AFTER" == "$CS_SHA" ]] || { echo "ERROR: cs mutated" >&2; exit 1; }

write_stage_meta "${META_DIR}/combined-profdata.json" \
  --arg base "$BASE" --arg base_sha "$BASE_SHA" \
  --arg cs "$CS" --arg cs_sha "$CS_SHA" \
  --arg combined "$COMBINED" --arg combined_sha "$COMB_SHA" \
  --argjson base_size "$BASE_SIZE" --argjson cs_size "$CS_SIZE" --argjson combined_size "$COMB_SIZE" \
  --argjson ord_funcs "$ORD_FUNCS" --argjson cs_funcs "$CS_FUNCS" \
  --arg created_utc "$COMB_TS" \
  --arg llvm "21.1.8" \
  '{stage:"C",base:$base,base_sha256:$base_sha,base_bytes:$base_size,cs:$cs,cs_sha256:$cs_sha,cs_bytes:$cs_size,combined:$combined,combined_sha256:$combined_sha,combined_bytes:$combined_size,ordinary_funcs:$ord_funcs,cs_funcs_showcs:$cs_funcs,created_utc:$created_utc,llvm_profdata:$llvm}'

echo "Stage C combined.profdata OK sha256=$COMB_SHA size=$COMB_SIZE ord_funcs=$ORD_FUNCS cs_funcs=$CS_FUNCS"
