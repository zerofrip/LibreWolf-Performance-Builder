#!/usr/bin/env bash
# Merge Stage B CS *.profraw -> cs.profdata ONLY (no base merge / no combined).
# Usage: merge-cs.sh [cs_raw_dir] [out_cs.profdata]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

CS_RAW_DIR="${1:-${PROF_DIR}/stage-b-raw}"
CS_OUT="${2:-${PROF_DIR}/cs.profdata}"
# Resolve to absolute paths under ROOT for docker -v mapping
CS_RAW_DIR="$(cd "$CS_RAW_DIR" && pwd)"
mkdir -p "$(dirname "$CS_OUT")" "$META_DIR"
CS_OUT="$(cd "$(dirname "$CS_OUT")" && pwd)/$(basename "$CS_OUT")"

mapfile -t RAWS < <(find "$CS_RAW_DIR" -type f -name '*.profraw' | sort)
[[ "${#RAWS[@]}" -gt 0 ]] || { echo "ERROR: no CS profraw in $CS_RAW_DIR" >&2; exit 1; }

# Validate every selected raw with pinned llvm-profdata 21.1.8 (fail-closed)
REL_RAWS=()
VALIDATE_LOG="${META_DIR}/stage-b-profraw-validate.log"
: >"$VALIDATE_LOG"
for f in "${RAWS[@]}"; do
  rel="${f#"$ROOT"/}"
  [[ "$rel" != "$f" ]] || { echo "ERROR: $f not under $ROOT" >&2; exit 1; }
  REL_RAWS+=("$rel")
done
CS_REL="${CS_OUT#"$ROOT"/}"
META_REL="${META_DIR#"$ROOT"/}"
[[ "$CS_REL" != "$CS_OUT" ]] || { echo "ERROR: cs out not under $ROOT" >&2; exit 1; }

docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
llvm-profdata --version | head -1 | tee /src/${META_REL}/llvm-profdata-version-stage-b.txt
echo \"== validate each CS profraw ==\" | tee -a /src/${META_REL}/stage-b-profraw-validate.log
fail=0
for f in $(printf '/src/%s ' "${REL_RAWS[@]}"); do
  echo \"-- \$f\" | tee -a /src/${META_REL}/stage-b-profraw-validate.log
  if ! llvm-profdata show --showcs \"\$f\" >> /src/${META_REL}/stage-b-profraw-validate.log 2>&1; then
    echo \"ERROR: malformed or unreadable \$f\" | tee -a /src/${META_REL}/stage-b-profraw-validate.log
    fail=1
  fi
done
[[ \"\$fail\" -eq 0 ]] || exit 1
echo \"== merge CS only (no base.profdata) ==\" | tee -a /src/${META_REL}/stage-b-cs-merge.log
llvm-profdata merge -output=/src/${CS_REL} $(printf '/src/%s ' "${REL_RAWS[@]}") \
  2> >(tee -a /src/${META_REL}/stage-b-cs-merge.log >&2)
llvm-profdata show /src/${CS_REL} > /src/${META_REL}/cs-profdata-show.txt
llvm-profdata show --showcs /src/${CS_REL} > /src/${META_REL}/cs-profdata-showcs.txt
llvm-profdata show --showcs --all-functions /src/${CS_REL} > /src/${META_REL}/cs-profdata-showcs-all.txt
"

require_nonempty "$CS_OUT"
CS_SHA="$(json_sha256 "$CS_OUT")"
CS_SIZE="$(stat -c%s "$CS_OUT")"
CS_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/cs-profdata-showcs.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
NOCS_FUNCS="$(grep -E 'Total functions:' "${META_DIR}/cs-profdata-show.txt" | head -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
if [[ "${CS_FUNCS:-0}" -le 0 ]]; then
  echo "ERROR: CS profile has no functions under --showcs" >&2
  head -40 "${META_DIR}/cs-profdata-showcs.txt" >&2
  exit 1
fi

# Refuse accidental combined creation in this script's scope
if [[ -f "${PROF_DIR}/combined.profdata" ]]; then
  echo "ERROR: combined.profdata present — Stage C not authorized; remove before merge-cs" >&2
  exit 1
fi

write_stage_meta "${META_DIR}/cs-profdata.json" \
  --arg cs "$CS_OUT" --arg cs_sha "$CS_SHA" \
  --argjson cs_size "$CS_SIZE" \
  --argjson raw_count "${#RAWS[@]}" \
  --argjson cs_funcs_showcs "${CS_FUNCS}" \
  --argjson cs_funcs_noshowcs "${NOCS_FUNCS:-0}" \
  --arg raw_dir "$CS_RAW_DIR" \
  '{stage:"B-cs-merge",cs:$cs,cs_sha256:$cs_sha,cs_bytes:$cs_size,raw_count:$raw_count,cs_funcs_showcs:$cs_funcs_showcs,cs_funcs_without_showcs:$cs_funcs_noshowcs,raw_dir:$raw_dir,combined:"NOT_CREATED"}'

echo "cs.profdata OK sha256=$CS_SHA size=$CS_SIZE cs_funcs_showcs=$CS_FUNCS (no combined)"
