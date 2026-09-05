#!/usr/bin/env bash
# Deterministic layout tests for Stage B base.profdata normalization (R1–R3).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NORM="${ROOT}/scripts/csir-fulltree/normalize-base-profdata.sh"
AUTH="${ROOT}/artifacts/csir-fulltree/runs/20260905TPhase6A/profiles/base.profdata"
EXPECT_SHA=6b57dfaba67d480726cabb016bb4a64fface2cbe79e8181ef65182514f17099a
EXPECT_SIZE=114720872
RUN_ID=20260905TPhase6A

[[ -s "$AUTH" ]] || { echo "ERROR: missing authoritative base at $AUTH" >&2; exit 1; }
sha="$(sha256sum "$AUTH" | awk '{print $1}')"
sz="$(stat -c%s "$AUTH")"
[[ "$sha" == "$EXPECT_SHA" && "$sz" == "$EXPECT_SIZE" ]] \
  || { echo "ERROR: authoritative base hash/size mismatch" >&2; exit 1; }

chmod +x "$NORM"

assert_canon() {
  local tmp="$1"
  local canon="$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles/base.profdata"
  test -s "$canon"
  [[ "$(sha256sum "$canon" | awk '{print $1}')" == "$EXPECT_SHA" ]]
  [[ "$(stat -c%s "$canon")" == "$EXPECT_SIZE" ]]
  if [[ -e "$tmp/profiles/base.profdata" ]] \
    && [[ "$(realpath "$tmp/profiles/base.profdata")" != "$(realpath "$canon")" ]]; then
    echo "ERROR: non-canonical profiles/base.profdata still present" >&2
    exit 1
  fi
  if [[ -e "$tmp/base.profdata" ]] \
    && [[ "$(realpath "$tmp/base.profdata")" != "$(realpath "$canon")" ]]; then
    echo "ERROR: non-canonical ./base.profdata still present" >&2
    exit 1
  fi
}

echo "== layout test: A (profiles/base.profdata) =="
tmp="$(mktemp -d)"
mkdir -p "$tmp/profiles"
cp -a "$AUTH" "$tmp/profiles/base.profdata"
bash "$NORM" "$RUN_ID" "$tmp"
assert_canon "$tmp"
rm -rf "$tmp"
echo "LAYOUT_A=PASS"

echo "== layout test: B (canonical path) =="
tmp="$(mktemp -d)"
mkdir -p "$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles"
cp -a "$AUTH" "$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles/base.profdata"
bash "$NORM" "$RUN_ID" "$tmp"
assert_canon "$tmp"
rm -rf "$tmp"
echo "LAYOUT_B=PASS"

echo "== layout test: C (./base.profdata) =="
tmp="$(mktemp -d)"
cp -a "$AUTH" "$tmp/base.profdata"
bash "$NORM" "$RUN_ID" "$tmp"
assert_canon "$tmp"
rm -rf "$tmp"
echo "LAYOUT_C=PASS"

echo "== layout test: AMBIGUOUS unequal =="
tmp="$(mktemp -d)"
mkdir -p "$tmp/profiles" "$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles"
cp -a "$AUTH" "$tmp/profiles/base.profdata"
echo 'not-the-base' >"$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles/base.profdata"
if bash "$NORM" "$RUN_ID" "$tmp"; then
  echo "ERROR: unequal candidates should FAIL" >&2
  exit 1
fi
rm -rf "$tmp"
echo "LAYOUT_AMBIGUOUS_UNEQUAL=PASS (rejected)"

echo "== layout test: DUPLICATE equal =="
tmp="$(mktemp -d)"
mkdir -p "$tmp/profiles" "$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles"
cp -a "$AUTH" "$tmp/profiles/base.profdata"
cp -a "$AUTH" "$tmp/artifacts/csir-fulltree/runs/${RUN_ID}/profiles/base.profdata"
bash "$NORM" "$RUN_ID" "$tmp"
assert_canon "$tmp"
rm -rf "$tmp"
echo "LAYOUT_DUPLICATE_EQUAL=PASS"

echo "BASE_ARTIFACT_LAYOUT_TESTS=PASS"
