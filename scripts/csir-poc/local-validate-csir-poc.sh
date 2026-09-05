#!/usr/bin/env bash
# Lightweight Phase 5 CSIR PoC validation (no full LibreWolf build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "== syntax =="
for s in scripts/csir-poc/*.sh; do
  bash -n "$s"
  echo "OK $s"
done

echo "== PoC source exists =="
test -f tests/csir-poc/csir_poc.c

echo "== probe CSIR flags =="
bash scripts/csir-poc/probe-csir-flags.sh
jq -e '
  .flags.fcs_profile_generate_alone == true
  and .flags.fprofile_generate_alone == true
  and .flags.fprofile_generate_plus_fcs_same_compile == "rejected"
' artifacts/csir-poc/meta/toolchain.json >/dev/null

echo "== negative: missing base profile build fails closed =="
if bash scripts/csir-poc/build-windows-poc.sh \
  artifacts/csir-poc/bin/neg-missing-base.exe \
  -fprofile-use=/src/artifacts/csir-poc/profiles/DOES_NOT_EXIST.profdata \
  -fcs-profile-generate=/src/artifacts/csir-poc/profiles/cs-out \
  2>/tmp/neg-base.err; then
  echo "ERROR: expected failure for missing base profile" >&2
  exit 1
fi
grep -Eiq 'Error in reading profile|No such file|ERROR' /tmp/neg-base.err
echo "OK missing base fails"

echo "== negative: wrong target not used by helper (target pin) =="
grep -q 'x86_64-pc-windows-msvc' scripts/csir-poc/docker-build-inner.sh

echo "== if prior pipeline artifacts exist, validate contracts =="
if [[ -f artifacts/csir-poc/meta/summary.json ]]; then
  jq -e '
    .cs_profile.context_sensitive == "PRESENT"
    and .final_build.profile_consumption == "PROVEN"
    and .final_run.windows_exit == 0
    and .thinlto_compat.build == "PASS"
    and .custom_llvm_required == false
  ' artifacts/csir-poc/meta/summary.json >/dev/null
  echo "OK summary contract"
fi

echo
echo "Phase 5 local-validate-csir-poc PASSED"
