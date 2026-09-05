#!/usr/bin/env bash
# Normalize downloaded Stage D combined.profdata to ONE canonical path.
# Usage: normalize-combined-profdata.sh <run_id> [workspace_root]
set -euo pipefail

RUN_ID="${1:?run_id}"
ROOT="${2:-.}"
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"

EXPECT_SHA="${LWPB_CSIR_COMBINED_EXPECT_SHA:-bd3b9602c8131568b7d95177f53748e09257655297b9fe7247dea330b55e56a9}"
EXPECT_SIZE="${LWPB_CSIR_COMBINED_EXPECT_SIZE:-150638760}"

CANON="artifacts/csir-fulltree/runs/${RUN_ID}/profiles/combined.profdata"
mkdir -p "$(dirname "$CANON")"

CANDIDATES=()
add_cand() {
  local p="$1"
  [[ -f "$p" && -s "$p" ]] || return 0
  local rp
  rp="$(realpath "$p")"
  local c
  for c in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    [[ "$(realpath "$c")" == "$rp" ]] && return 0
  done
  CANDIDATES+=("$p")
}

add_cand "$CANON"
add_cand "profiles/combined.profdata"
add_cand "combined.profdata"

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  echo "ERROR: no combined.profdata candidate under $ROOT" >&2
  exit 1
fi

declare -A BY_SHA=()
for p in "${CANDIDATES[@]}"; do
  sha="$(sha256sum "$p" | awk '{print $1}')"
  sz="$(stat -c%s "$p")"
  echo "candidate path=$p size=$sz sha256=$sha"
  BY_SHA["$sha"]="$p"
done

if [[ "${#BY_SHA[@]}" -gt 1 ]]; then
  echo "ERROR: multiple unequal combined.profdata candidates:" >&2
  for sha in "${!BY_SHA[@]}"; do
    echo "  $sha -> ${BY_SHA[$sha]}" >&2
  done
  exit 1
fi

mapfile -t SHA_KEYS < <(printf '%s\n' "${!BY_SHA[@]}")
GOT_SHA="${SHA_KEYS[0]}"
SRC="${BY_SHA[$GOT_SHA]}"
GOT_SIZE="$(stat -c%s "$SRC")"

if [[ "$GOT_SHA" != "$EXPECT_SHA" ]]; then
  echo "ERROR: combined SHA256 mismatch got=$GOT_SHA expect=$EXPECT_SHA" >&2
  exit 1
fi
if [[ "$GOT_SIZE" != "$EXPECT_SIZE" ]]; then
  echo "ERROR: combined size mismatch got=$GOT_SIZE expect=$EXPECT_SIZE" >&2
  exit 1
fi

if [[ "$(realpath "$SRC")" != "$(realpath "$CANON" 2>/dev/null || echo "")" ]]; then
  cp -a "$SRC" "$CANON"
  echo "normalized: $SRC -> $CANON"
  # Remove non-canonical slots of same content
  for p in "${CANDIDATES[@]}"; do
    [[ "$(realpath "$p")" == "$(realpath "$CANON")" ]] && continue
    if [[ "$(sha256sum "$p" | awk '{print $1}')" == "$GOT_SHA" ]]; then
      rm -f "$p"
      echo "removed non-canonical slot: $p"
    fi
  done
fi

echo "CANONICAL_COMBINED=$CANON"
echo "CANONICAL_SHA256=$GOT_SHA"
echo "CANONICAL_SIZE=$GOT_SIZE"
echo "NORMALIZE_COMBINED_PROFDATA=PASS"
