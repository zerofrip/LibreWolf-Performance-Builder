#!/usr/bin/env bash
# Merge Stage A *.profraw -> base.profdata (pinned llvm-profdata 21.1.8 via bsys6 image).
# Usage: merge-base.sh [profraw_dir] [out_profdata]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

RAW_DIR="${1:-${PROF_DIR}/stage-a-raw}"
OUT="${2:-${PROF_DIR}/base.profdata}"
mkdir -p "$(dirname "$OUT")" "$META_DIR"

mapfile -t RAWS < <(find "$RAW_DIR" -type f -name '*.profraw' | sort)
[[ "${#RAWS[@]}" -gt 0 ]] || { echo "ERROR: no profraw in $RAW_DIR" >&2; exit 1; }

# Relativize for docker mount
REL_RAWS=()
for f in "${RAWS[@]}"; do
  rel="${f#"$ROOT"/}"
  [[ "$rel" != "$f" ]] || { echo "ERROR: $f not under $ROOT" >&2; exit 1; }
  REL_RAWS+=("$rel")
done
OUT_REL="${OUT#"$ROOT"/}"

docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc "
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:\$PATH
llvm-profdata --version | head -1 | tee /src/${META_DIR#"$ROOT"/}/llvm-profdata-version.txt
llvm-profdata merge -output=/src/${OUT_REL} $(printf '/src/%s ' "${REL_RAWS[@]}")
llvm-profdata show --all-functions /src/${OUT_REL} > /src/${META_DIR#"$ROOT"/}/base-profdata-show.txt
llvm-profdata show /src/${OUT_REL} > /src/${META_DIR#"$ROOT"/}/base-profdata-show-summary.txt
"

require_nonempty "$OUT"
# Require browser-ish symbols (not empty / trivial)
if ! grep -Eiq 'mozilla|xul|ns|Gecko|librewolf|moz' "${META_DIR}/base-profdata-show.txt"; then
  echo "ERROR: base.profdata show lacks expected browser symbols" >&2
  head -80 "${META_DIR}/base-profdata-show.txt" >&2 || true
  exit 1
fi

SHA="$(json_sha256 "$OUT")"
SIZE="$(stat -c%s "$OUT")"
write_stage_meta "${META_DIR}/base-profdata.json" \
  --arg out "$OUT" \
  --arg sha "$SHA" \
  --argjson size "$SIZE" \
  --argjson raw_count "${#RAWS[@]}" \
  --arg show_summary "$(head -40 "${META_DIR}/base-profdata-show-summary.txt")" \
  '{stage:"A-merge",output:$out,sha256:$sha,bytes:$size,raw_count:$raw_count,show_summary:$show_summary}'

echo "base.profdata OK sha256=$SHA size=$SIZE"
