#!/usr/bin/env bash
# Regression: Stage B must reject ONLY active ac_add_options --enable-profile-generate.
# Must not fail on comments or unrelated text that mention the flag string.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Exact matcher used by build-stage-b.sh (keep in sync).
ACTIVE_PG='^[[:space:]]*ac_add_options[[:space:]]+--enable-profile-generate'

pass=0
fail=0

expect_no_match() {
  local name="$1" body="$2"
  if printf '%s\n' "$body" | grep -Eq "$ACTIVE_PG"; then
    echo "FAIL: $name — unexpected ACTIVE match"
    fail=$((fail + 1))
  else
    echo "PASS: $name — no active match"
    pass=$((pass + 1))
  fi
}

expect_match() {
  local name="$1" body="$2"
  if printf '%s\n' "$body" | grep -Eq "$ACTIVE_PG"; then
    echo "PASS: $name — active directive detected"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — active directive missed"
    fail=$((fail + 1))
  fi
}

# R1: comment only
expect_no_match "comment_only" \
  '# Must NOT also --enable-profile-generate'

# R1: active directive
expect_match "active_directive" \
  'ac_add_options --enable-profile-generate'

# R1: whitespace before active (mozconfig allows leading spaces)
expect_match "whitespace_before_active" \
  '  ac_add_options --enable-profile-generate'

# R1: unrelated text containing the string
expect_no_match "unrelated_text" \
  'echo "docs mention --enable-profile-generate for Stage A only"'

# Real Stage B frag comment (exact production text)
expect_no_match "cs_gen_frag_comment" \
  "$(cat "${ROOT}/configs/mozconfig.csir-cs-gen.frag")"

# Apply Stage B on a fixture: final backup must have use+CSIR, no active generate
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE_DIR="${ROOT}/artifacts/csir-fulltree/runs/20260905TPhase6A/profiles"
BASE="${BASE_DIR}/base.profdata"
if [[ ! -s "$BASE" ]]; then
  echo "ERROR: authoritative base.profdata missing at $BASE" >&2
  exit 1
fi
cp "$BASE" "$TMP/base.profdata"
printf '%s\n' \
  '# fixture mozconfig.backup' \
  'ac_add_options --enable-optimize' \
  >"$TMP/mozconfig.backup"
mkdir -p "$TMP/cs-gen"
bash "${ROOT}/scripts/csir-fulltree/apply-stage-b-mozconfig.sh" \
  "$TMP/mozconfig.backup" "$TMP/base.profdata" "$TMP/cs-gen"

OUT="$TMP/mozconfig.backup"
if grep -Eq "$ACTIVE_PG" "$OUT"; then
  echo "FAIL: applied Stage B mozconfig still has active profile-generate"
  fail=$((fail + 1))
else
  echo "PASS: applied Stage B — active profile-generate ABSENT"
  pass=$((pass + 1))
fi
if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-profile-use' "$OUT"; then
  echo "PASS: applied Stage B — profile-use PRESENT"
  pass=$((pass + 1))
else
  echo "FAIL: applied Stage B — profile-use missing"
  fail=$((fail + 1))
fi
if grep -Eq 'fcs-profile-generate' "$OUT"; then
  echo "PASS: applied Stage B — CSIR generation REQUESTED"
  pass=$((pass + 1))
else
  echo "FAIL: applied Stage B — CSIR generation missing"
  fail=$((fail + 1))
fi
if grep -Eq 'windows\.profdata' "$OUT"; then
  echo "FAIL: applied Stage B mentions windows.profdata"
  fail=$((fail + 1))
else
  echo "PASS: applied Stage B — no windows.profdata authority"
  pass=$((pass + 1))
fi

# Confirm build-stage-b.sh still uses the same ACTIVE_PG pattern
if grep -Fq "$ACTIVE_PG" "${ROOT}/scripts/csir-fulltree/build-stage-b.sh"; then
  echo "PASS: build-stage-b.sh matcher in sync"
  pass=$((pass + 1))
else
  echo "FAIL: build-stage-b.sh matcher drifted from test"
  fail=$((fail + 1))
fi

echo "profile-generate-gate: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
echo "PROFILE_GENERATE_GATE_TEST=PASS"
