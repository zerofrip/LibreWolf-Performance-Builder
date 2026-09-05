#!/usr/bin/env bash
# Normalize downloaded Stage B base.profdata to ONE canonical path.
# Usage:
#   normalize-base-profdata.sh <run_id> [workspace_root]
#
# Known download layouts (deterministic; no find|head):
#   LAYOUT A: profiles/base.profdata          (upload-artifact LCA strip)
#   LAYOUT B: artifacts/csir-fulltree/runs/<id>/profiles/base.profdata
#   LAYOUT C: base.profdata                  (single-file artifact root)
#
# Authority is SHA256 (+ size), not path. Hash mismatch => FAIL.
# Multiple unequal candidates => FAIL.
set -euo pipefail

RUN_ID="${1:?run_id}"
ROOT="${2:-.}"
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"

EXPECT_SHA="${LWPB_CSIR_BASE_EXPECT_SHA:-6b57dfaba67d480726cabb016bb4a64fface2cbe79e8181ef65182514f17099a}"
EXPECT_SIZE="${LWPB_CSIR_BASE_EXPECT_SIZE:-114720872}"

CANON="artifacts/csir-fulltree/runs/${RUN_ID}/profiles/base.profdata"
mkdir -p "$(dirname "$CANON")"

# Ordered candidate slots (path identity only; later filtered by hash)
CANDIDATES=()
add_cand() {
  local p="$1"
  [[ -f "$p" && -s "$p" ]] || return 0
  # de-dupe by realpath
  local rp
  rp="$(realpath "$p")"
  local c
  for c in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    [[ "$(realpath "$c")" == "$rp" ]] && return 0
  done
  CANDIDATES+=("$p")
}

add_cand "$CANON"
add_cand "profiles/base.profdata"
add_cand "base.profdata"

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  echo "ERROR: no base.profdata candidate under $ROOT" >&2
  exit 1
fi

declare -A BY_SHA=()
for p in "${CANDIDATES[@]}"; do
  sha="$(sha256sum "$p" | awk '{print $1}')"
  sz="$(stat -c%s "$p")"
  echo "candidate path=$p size=$sz sha256=$sha"
  if [[ -n "${BY_SHA[$sha]:-}" && "$(realpath "${BY_SHA[$sha]}")" != "$(realpath "$p")" ]]; then
    # same hash, different path: OK (duplicates of same content)
    :
  fi
  BY_SHA["$sha"]="$p"
done

if [[ "${#BY_SHA[@]}" -gt 1 ]]; then
  echo "ERROR: multiple unequal base.profdata candidates (ambiguous authority):" >&2
  for sha in "${!BY_SHA[@]}"; do
    echo "  $sha -> ${BY_SHA[$sha]}" >&2
  done
  exit 1
fi

# Exactly one content identity
mapfile -t SHA_KEYS < <(printf '%s\n' "${!BY_SHA[@]}")
[[ "${#SHA_KEYS[@]}" -eq 1 ]] || { echo "ERROR: internal sha key count" >&2; exit 1; }
GOT_SHA="${SHA_KEYS[0]}"
SRC="${BY_SHA[$GOT_SHA]}"
GOT_SIZE="$(stat -c%s "$SRC")"

if [[ "$GOT_SHA" != "$EXPECT_SHA" ]]; then
  echo "ERROR: base SHA256 mismatch got=$GOT_SHA expect=$EXPECT_SHA" >&2
  exit 1
fi
if [[ "$GOT_SIZE" != "$EXPECT_SIZE" ]]; then
  echo "ERROR: base size mismatch got=$GOT_SIZE expect=$EXPECT_SIZE" >&2
  exit 1
fi

# Place at canonical path (copy if needed; remove other known slots afterward)
if [[ -e "$CANON" ]] && [[ "$(realpath "$SRC")" == "$(realpath "$CANON")" ]]; then
  :
else
  cp -a "$SRC" "$CANON"
fi
# Verify canonical
test -s "$CANON"
CANON_SHA="$(sha256sum "$CANON" | awk '{print $1}')"
CANON_SIZE="$(stat -c%s "$CANON")"
[[ "$CANON_SHA" == "$EXPECT_SHA" ]] || { echo "ERROR: canonical hash mismatch" >&2; exit 1; }
[[ "$CANON_SIZE" == "$EXPECT_SIZE" ]] || { echo "ERROR: canonical size mismatch" >&2; exit 1; }

# Remove non-canonical known slots to prevent dual authority
for extra in profiles/base.profdata base.profdata; do
  if [[ -e "$extra" ]] && [[ "$(realpath "$extra")" != "$(realpath "$CANON")" ]]; then
    rm -f "$extra"
    echo "removed non-canonical slot: $extra"
  fi
done
# If profiles/ is now empty, leave directory (harmless)

echo "CANONICAL_BASE=$CANON"
echo "CANONICAL_SHA256=$CANON_SHA"
echo "CANONICAL_SIZE=$CANON_SIZE"
echo "NORMALIZE_BASE_PROFDATA=PASS"
