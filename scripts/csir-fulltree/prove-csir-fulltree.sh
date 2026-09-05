#!/usr/bin/env bash
# Prove Phase 6 full-tree CSIR evidence from a run directory.
# Usage: prove-csir-fulltree.sh [run_dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

RUN="${1:-$RUN_DIR}"
META="${RUN}/meta"
PROF="${RUN}/profiles"
OUT_JSON="${META}/csir-fulltree-proof.json"
mkdir -p "$META"

fail=0
note() { echo "$*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

stage_a_instr="UNKNOWN"
stage_b_use="UNKNOWN"
stage_b_cs="UNKNOWN"
stage_b_no_gen="UNKNOWN"
cs_records="UNKNOWN"
combined_ok="UNKNOWN"
stage_d_use="UNKNOWN"
stage_d_no_cs="UNKNOWN"
stage_d_v3="UNKNOWN"
stage_d_thin="UNKNOWN"

if [[ -f "${META}/mozconfig-stage-a.txt" ]] && grep -Eq -- 'profile-generate' "${META}/mozconfig-stage-a.txt"; then
  if [[ -f "${META}/bsys6-build-package.log" ]] || [[ -f "${META}/compiler-invocations.jsonl" ]]; then
    if grep -Eq -- 'fprofile-generate|PROFILE_GEN|profile-generate' \
      "${META}/bsys6-build-package.log" "${META}/compiler-invocations.jsonl" 2>/dev/null; then
      stage_a_instr="PROVEN"
    else
      stage_a_instr="REQUESTED"
    fi
  fi
fi
[[ -f "${PROF}/base.profdata" ]] || bad "missing base.profdata"

if [[ -f "${META}/mozconfig-stage-b.txt" ]]; then
  grep -Eq -- 'fcs-profile-generate' "${META}/mozconfig-stage-b.txt" && stage_b_cs="REQUESTED" || stage_b_cs="OFF"
  grep -Eq -- 'profile-use|pgo-profile-path' "${META}/mozconfig-stage-b.txt" && stage_b_use="REQUESTED" || stage_b_use="OFF"
  if grep -Eq -- 'profile-generate' "${META}/mozconfig-stage-b.txt" && ! grep -Eq -- 'fcs-profile-generate' <<<"$(grep profile-generate "${META}/mozconfig-stage-b.txt" || true)"; then
    stage_b_no_gen="FAIL"
    bad "Stage B mozconfig still has profile-generate"
  else
    stage_b_no_gen="PASS"
  fi
fi
if [[ -f "${META}/compiler-invocations.jsonl" ]] && grep -Eq -- 'fcs-profile-generate' "${META}/compiler-invocations.jsonl"; then
  stage_b_cs="PROVEN"
fi
if [[ -f "${META}/compiler-invocations.jsonl" ]] && grep -Eq -- 'fprofile-use' "${META}/compiler-invocations.jsonl"; then
  stage_b_use="PROVEN"
fi

if [[ -f "${META}/cs-profdata-showcs.txt" ]]; then
  if grep -Eq 'Total functions:[[:space:]]*[1-9]' "${META}/cs-profdata-showcs.txt"; then
    cs_records="PROVEN"
  else
    cs_records="FAIL"
    bad "CS records missing"
  fi
fi

if [[ -f "${PROF}/combined.profdata" && -f "${META}/combined-profdata-showcs.txt" ]]; then
  combined_ok="PROVEN"
fi

if [[ -f "${META}/combined-profile-consumption.txt" ]]; then
  grep -q 'PROVEN' "${META}/combined-profile-consumption.txt" && stage_d_use="PROVEN" || stage_d_use="UNKNOWN"
fi
if [[ -f "${META}/mozconfig-stage-d.txt" ]]; then
  grep -Eq -- 'fcs-profile-generate' "${META}/mozconfig-stage-d.txt" && stage_d_no_cs="FAIL" || stage_d_no_cs="PASS"
fi
if [[ -f "${META}/v3-proof.json" ]]; then
  jq -e '.pass == true or .overall == "PASS" or .result == "PASS"' "${META}/v3-proof.json" >/dev/null 2>&1 \
    && stage_d_v3="PROVEN" || stage_d_v3="PRESENT"
fi
if [[ -f "${META}/thinlto-proof.json" ]]; then
  jq -e '.pass == true or .overall == "PASS" or .result == "PASS" or .thinlto_effective == true' \
    "${META}/thinlto-proof.json" >/dev/null 2>&1 \
    && stage_d_thin="PROVEN" || stage_d_thin="PRESENT"
fi

jq -n \
  --arg stage_a_instr "$stage_a_instr" \
  --arg stage_b_use "$stage_b_use" \
  --arg stage_b_cs "$stage_b_cs" \
  --arg stage_b_no_gen "$stage_b_no_gen" \
  --arg cs_records "$cs_records" \
  --arg combined_ok "$combined_ok" \
  --arg stage_d_use "$stage_d_use" \
  --arg stage_d_no_cs "$stage_d_no_cs" \
  --arg stage_d_v3 "$stage_d_v3" \
  --arg stage_d_thin "$stage_d_thin" \
  --arg run "$RUN" \
  '{
    run:$run,
    stage_a_instrumentation:$stage_a_instr,
    stage_b_base_profile_use:$stage_b_use,
    stage_b_csir:$stage_b_cs,
    stage_b_no_profile_generate:$stage_b_no_gen,
    cs_context_sensitive_records:$cs_records,
    combined_profile:$combined_ok,
    stage_d_combined_use:$stage_d_use,
    stage_d_cs_generate_off:$stage_d_no_cs,
    stage_d_v3:$stage_d_v3,
    stage_d_thinlto:$stage_d_thin
  }' | tee "$OUT_JSON"

[[ "$fail" -eq 0 ]] || exit 1
echo "prove-csir-fulltree: structural checks written to $OUT_JSON"
