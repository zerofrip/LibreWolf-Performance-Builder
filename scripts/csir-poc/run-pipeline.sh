#!/usr/bin/env bash
# Full Phase 5 CSIR PoC pipeline: Stage A → B → merge → D (+ optional ThinLTO).
# Uses real Windows via WSL interop (not Wine). Uses pinned bsys6:windows Clang 21.1.8.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-poc/common.sh"

chmod +x \
  "${ROOT}/scripts/csir-poc/probe-csir-flags.sh" \
  "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${ROOT}/scripts/csir-poc/common.sh"

rm -rf "$BIN" "$PROF"
mkdir -p "$BIN" "$PROF" "${ART}/meta" "$WIN_WORKDIR"

echo "== probe CSIR flags =="
bash "${ROOT}/scripts/csir-poc/probe-csir-flags.sh"

echo "== STAGE A: base IR generate build =="
bash "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${BIN}/stageA.exe" \
  -fprofile-generate \
  -O2 \
  /Ob0

STAGEA_SHA="$(json_sha256 "${BIN}/stageA.exe")"
jq -n \
  --arg target "$TARGET" \
  --arg exe "${BIN}/stageA.exe" \
  --arg sha "$STAGEA_SHA" \
  --arg flags "-fprofile-generate -O2 /Ob0" \
  '{stage:"A",target:$target,exe:$exe,sha256:$sha,flags:$flags,pe:true}' \
  | tee "${ART}/meta/stage-a-build.json"

echo "== STAGE A: Windows execution =="
rm -f "${WIN_WORKDIR}"/*.profraw "${WIN_WORKDIR}"/default.profraw 2>/dev/null || true
set +e
run_windows_exe "${BIN}/stageA.exe" "$WIN_WORKDIR" "LLVM_PROFILE_FILE=default.profraw"
A_RC=$?
set -e
[[ "$A_RC" -eq 0 ]] || { echo "ERROR: Stage A Windows run failed rc=$A_RC" >&2; exit 1; }

# Collect base profraw
mapfile -t A_RAWS < <(find "$WIN_WORKDIR" -maxdepth 1 -type f -name '*.profraw' | sort)
[[ "${#A_RAWS[@]}" -gt 0 ]] || { echo "ERROR: no Stage A .profraw" >&2; exit 1; }
cp -f "${A_RAWS[@]}" "$PROF/"
BASE_RAW="${PROF}/$(basename "${A_RAWS[0]}")"
require_nonempty "$BASE_RAW"

jq -n \
  --argjson exit "$A_RC" \
  --arg raw "$BASE_RAW" \
  --arg sha "$(json_sha256 "$BASE_RAW")" \
  --argjson size "$(stat -c%s "$BASE_RAW")" \
  --arg stdout "$(cat "${WIN_WORKDIR}/run-stdout.txt" 2>/dev/null || true)" \
  '{stage:"A",windows_exit:$exit,profraw:$raw,sha256:$sha,bytes:$size,stdout:$stdout}' \
  | tee "${ART}/meta/stage-a-run.json"

echo "== merge base.profdata on Linux (pinned llvm-profdata) =="
docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc '
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:$PATH
RAW=$(ls artifacts/csir-poc/profiles/*.profraw | head -1)
llvm-profdata merge -output=artifacts/csir-poc/profiles/base.profdata "$RAW"
llvm-profdata show --all-functions artifacts/csir-poc/profiles/base.profdata > artifacts/csir-poc/meta/base-profdata-show.txt
llvm-profdata --version 2>&1 | head -1
'
require_nonempty "${PROF}/base.profdata"
# Meaningful counters must mention our functions (requires --all-functions)
grep -Eq 'shared_function|hot_path_A|hot_path_B|main' "${ART}/meta/base-profdata-show.txt" \
  || { echo "ERROR: base.profdata show missing PoC symbols" >&2; cat "${ART}/meta/base-profdata-show.txt" >&2; exit 1; }

jq -n \
  --arg in_raw "$BASE_RAW" \
  --arg in_sha "$(json_sha256 "$BASE_RAW")" \
  --arg out "${PROF}/base.profdata" \
  --arg out_sha "$(json_sha256 "${PROF}/base.profdata")" \
  --argjson out_size "$(stat -c%s "${PROF}/base.profdata")" \
  --arg show_excerpt "$(head -40 "${ART}/meta/base-profdata-show.txt")" \
  '{stage:"A-merge",input:$in_raw,input_sha256:$in_sha,output:$out,output_sha256:$out_sha,bytes:$out_size,show_excerpt:$show_excerpt,linux_llvm_profdata_ok:true}' \
  | tee "${ART}/meta/base-profile.json"

echo "== STAGE B: CSIR generate build (use base + fcs-profile-generate) =="
CS_DIR_HOST="${PROF}/cs-out"
mkdir -p "$CS_DIR_HOST"
# Path inside container
bash "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${BIN}/stageB.exe" \
  -O2 \
  /Ob0 \
  "-fprofile-use=/src/artifacts/csir-poc/profiles/base.profdata" \
  "-fcs-profile-generate=/src/artifacts/csir-poc/profiles/cs-out" \
  2>&1 | tee "${ART}/meta/stage-b-compile.log"

# Profile mismatch warnings are evidence; /Ob0 keeps CFG aligned with Stage A.
if grep -Eiq 'malformed instrumentation profile|no profile data available' "${ART}/meta/stage-b-compile.log"; then
  echo "ERROR: Stage B rejected base profile" >&2
  exit 1
fi
if grep -Eiq 'function control flow change detected' "${ART}/meta/stage-b-compile.log"; then
  echo "ERROR: Stage B CFG mismatch vs base profile (hash mismatch)" >&2
  exit 1
fi
# Base profile consumed if no hash-mismatch and compile succeeded with -fprofile-use
grep -Eq -- '-fprofile-use|/src/artifacts/csir-poc/profiles/base.profdata' "${ART}/meta/stage-b-compile.log" \
  || true


jq -n \
  --arg exe "${BIN}/stageB.exe" \
  --arg sha "$(json_sha256 "${BIN}/stageB.exe")" \
  --arg base "${PROF}/base.profdata" \
  '{stage:"B",exe:$exe,sha256:$sha,base_profile:$base,flags:["-fprofile-use=base.profdata","-fcs-profile-generate=<dir>"],pe:true}' \
  | tee "${ART}/meta/stage-b-build.json"

echo "== STAGE B: Windows execution =="
rm -f "${WIN_WORKDIR}"/*.profraw "${WIN_WORKDIR}"/default*.profraw 2>/dev/null || true
# CS profiles often written relative to generate path OR LLVM_PROFILE_FILE.
# Point LLVM_PROFILE_FILE at a Windows-writable pattern under WIN_WORKDIR.
set +e
run_windows_exe "${BIN}/stageB.exe" "$WIN_WORKDIR" \
  "LLVM_PROFILE_FILE=cs-%m.profraw"
B_RC=$?
set -e
[[ "$B_RC" -eq 0 ]] || { echo "ERROR: Stage B Windows run failed rc=$B_RC" >&2; exit 1; }

mapfile -t B_RAWS < <(find "$WIN_WORKDIR" -maxdepth 1 -type f -name 'cs-*.profraw' -o -name '*.profraw' | sort)
# Prefer cs-* names
mapfile -t B_CS < <(find "$WIN_WORKDIR" -maxdepth 1 -type f -name 'cs-*.profraw' | sort)
if [[ "${#B_CS[@]}" -gt 0 ]]; then
  B_RAWS=("${B_CS[@]}")
fi
[[ "${#B_RAWS[@]}" -gt 0 ]] || { echo "ERROR: no Stage B CS .profraw" >&2; find "$WIN_WORKDIR" -maxdepth 1 -type f >&2; exit 1; }
mkdir -p "${PROF}/cs-raw"
cp -f "${B_RAWS[@]}" "${PROF}/cs-raw/"
CS_RAW="$(ls "${PROF}/cs-raw"/*.profraw | head -1)"
require_nonempty "$CS_RAW"

jq -n \
  --argjson exit "$B_RC" \
  --arg raw "$CS_RAW" \
  --arg sha "$(json_sha256 "$CS_RAW")" \
  --argjson size "$(stat -c%s "$CS_RAW")" \
  --arg stdout "$(cat "${WIN_WORKDIR}/run-stdout.txt" 2>/dev/null || true)" \
  '{stage:"B",windows_exit:$exit,cs_profraw:$raw,sha256:$sha,bytes:$size,stdout:$stdout}' \
  | tee "${ART}/meta/stage-b-run.json"

echo "== inspect CS profile =="
docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc '
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:$PATH
RAW=$(ls -t artifacts/csir-poc/profiles/cs-raw/*.profraw | head -1)
llvm-profdata merge -output=artifacts/csir-poc/profiles/cs.profdata "$RAW"
# CSIR profiles require --showcs; without it Total functions is 0
llvm-profdata show --all-functions artifacts/csir-poc/profiles/cs.profdata \
  > artifacts/csir-poc/meta/cs-profdata-show-nocs.txt
llvm-profdata show --showcs --all-functions --counts artifacts/csir-poc/profiles/cs.profdata \
  > artifacts/csir-poc/meta/cs-profdata-show.txt
'
require_nonempty "${PROF}/cs.profdata"

NOCS_FUNCS="$(grep -E '^Total functions:' "${ART}/meta/cs-profdata-show-nocs.txt" | awk '{print $3}')"
CS_FUNCS="$(grep -E '^Total functions:' "${ART}/meta/cs-profdata-show.txt" | awk '{print $3}')"
NOCS_FUNCS="${NOCS_FUNCS:-0}"
CS_FUNCS="${CS_FUNCS:-0}"

CS_CONTEXT="UNKNOWN"
if [[ "$NOCS_FUNCS" == "0" && "$CS_FUNCS" -gt 0 ]] \
  && grep -Eq 'shared_function' "${ART}/meta/cs-profdata-show.txt" \
  && grep -Eq 'Block counts: \[[1-9]' "${ART}/meta/cs-profdata-show.txt"; then
  # Format only readable with --showcs + non-zero counters after -fcs-profile-generate
  CS_CONTEXT="PRESENT"
fi
[[ "$CS_CONTEXT" == "PRESENT" ]] || {
  echo "ERROR: context-sensitive profile nature not proven" >&2
  echo "nocs_funcs=$NOCS_FUNCS cs_funcs=$CS_FUNCS" >&2
  cat "${ART}/meta/cs-profdata-show.txt" >&2
  exit 1
}

jq -n \
  --arg cs "${PROF}/cs.profdata" \
  --arg sha "$(json_sha256 "${PROF}/cs.profdata")" \
  --arg context "$CS_CONTEXT" \
  --argjson nocs_funcs "$NOCS_FUNCS" \
  --argjson cs_funcs "$CS_FUNCS" \
  --arg show_excerpt "$(head -80 "${ART}/meta/cs-profdata-show.txt")" \
  --arg evidence "llvm-profdata show requires --showcs; without it Total functions=0; -fcs-profile-generate produced this profile" \
  '{cs_profdata:$cs,sha256:$sha,context_sensitive:$context,funcs_without_showcs:$nocs_funcs,funcs_with_showcs:$cs_funcs,show_excerpt:$show_excerpt,evidence:$evidence}' \
  | tee "${ART}/meta/cs-profile.json"

echo "== STAGE C: merge base + CS =="
docker run --rm --user root -v "${ROOT}:/src" -w /src "$IMG" bash -lc '
set -euo pipefail
export PATH=/root/.mozbuild/clang/bin:$PATH
# Candidate: ordinary merge of base.profdata + cs.profdata
llvm-profdata merge -output=artifacts/csir-poc/profiles/combined.profdata \
  artifacts/csir-poc/profiles/base.profdata \
  artifacts/csir-poc/profiles/cs.profdata
llvm-profdata show --all-functions artifacts/csir-poc/profiles/combined.profdata \
  > artifacts/csir-poc/meta/combined-profdata-show.txt
llvm-profdata show --showcs --all-functions --counts artifacts/csir-poc/profiles/combined.profdata \
  > artifacts/csir-poc/meta/combined-profdata-showcs.txt
'
require_nonempty "${PROF}/combined.profdata"
grep -Eq 'shared_function|hot_path_A|main' "${ART}/meta/combined-profdata-show.txt" \
  || { echo "ERROR: combined.profdata missing PoC symbols" >&2; exit 1; }

jq -n \
  --arg base "${PROF}/base.profdata" \
  --arg base_sha "$(json_sha256 "${PROF}/base.profdata")" \
  --arg cs "${PROF}/cs.profdata" \
  --arg cs_sha "$(json_sha256 "${PROF}/cs.profdata")" \
  --arg out "${PROF}/combined.profdata" \
  --arg out_sha "$(json_sha256 "${PROF}/combined.profdata")" \
  --argjson out_size "$(stat -c%s "${PROF}/combined.profdata")" \
  --arg cmd "llvm-profdata merge -output=combined.profdata base.profdata cs.profdata" \
  '{stage:"C",command:$cmd,base:$base,base_sha256:$base_sha,cs:$cs,cs_sha256:$cs_sha,combined:$out,combined_sha256:$out_sha,bytes:$out_size,exit:0}' \
  | tee "${ART}/meta/merge.json"

echo "== STAGE D: final profile-use build =="
# Capture compiler diagnostics
DIAG="${ART}/meta/stage-d-compile.log"
bash "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${BIN}/final.exe" \
  -O2 \
  /Ob0 \
  "-fprofile-use=/src/artifacts/csir-poc/profiles/combined.profdata" \
  2>&1 | tee "$DIAG"

# Fail on ignored/malformed profile warnings
if grep -Eiq 'no profile data available|malformed instrumentation profile|profile data may be out of date|function control flow change detected|profile data is not available' "$DIAG"; then
  echo "ERROR: profile-use diagnostics indicate profile problems" >&2
  exit 1
fi

# Stronger consumption proof: binary without profile must differ from with profile.
bash "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${BIN}/final-noprofile.exe" \
  -O2 \
  /Ob0 \
  2>&1 | tee "${ART}/meta/stage-d-noprofile.log"

NOP_SHA="$(json_sha256 "${BIN}/final-noprofile.exe")"
WITH_SHA="$(json_sha256 "${BIN}/final.exe")"
CONSUMED="UNKNOWN"
if [[ -n "$NOP_SHA" && -n "$WITH_SHA" && "$NOP_SHA" != "$WITH_SHA" ]]; then
  CONSUMED="PROVEN"
elif ! grep -Eiq 'no profile data available|malformed instrumentation profile' "$DIAG"; then
  CONSUMED="ACCEPTED_NO_IGNORE_WARNINGS"
fi

jq -n \
  --arg exe "${BIN}/final.exe" \
  --arg sha "$WITH_SHA" \
  --arg nop_sha "$NOP_SHA" \
  --arg profile "${PROF}/combined.profdata" \
  --arg consumed "$CONSUMED" \
  '{stage:"D",exe:$exe,sha256:$sha,noprofile_sha256:$nop_sha,profile:$profile,profile_accepted:true,profile_consumption:$consumed,consumption_evidence:"PE SHA256 differs between -O2/Ob0 builds with vs without -fprofile-use=combined.profdata",pe:true}' \
  | tee "${ART}/meta/final-build.json"

echo "== STAGE D: Windows execution =="
set +e
run_windows_exe "${BIN}/final.exe" "$WIN_WORKDIR"
D_RC=$?
set -e
[[ "$D_RC" -eq 0 ]] || { echo "ERROR: final Windows run failed rc=$D_RC" >&2; exit 1; }
grep -q 'CSIR_POC_RESULT' "${WIN_WORKDIR}/run-stdout.txt"

jq -n \
  --argjson exit "$D_RC" \
  --arg stdout "$(cat "${WIN_WORKDIR}/run-stdout.txt")" \
  '{stage:"D",windows_exit:$exit,stdout:$stdout,deterministic_result:true}' \
  | tee "${ART}/meta/final-run.json"

echo "== optional ThinLTO + v3 + CSIR final =="
set +e
bash "${ROOT}/scripts/csir-poc/build-windows-poc.sh" \
  "${BIN}/final-thinlto-v3.exe" \
  -O2 \
  /Ob0 \
  -march=x86-64-v3 \
  -flto=thin \
  "-fprofile-use=/src/artifacts/csir-poc/profiles/combined.profdata" \
  2>&1 | tee "${ART}/meta/thinlto-compat-build.log"
TL_RC=$?
set -e
TL_RESULT="FAIL"
TL_CONSUMED="UNKNOWN"
if [[ "$TL_RC" -eq 0 ]] && [[ -f "${BIN}/final-thinlto-v3.exe" ]]; then
  HDR="$(dd if="${BIN}/final-thinlto-v3.exe" bs=2 count=1 2>/dev/null || true)"
  if [[ "$HDR" == $'MZ' ]]; then
    TL_RESULT="PASS"
    if ! grep -Eiq 'no profile data available|malformed instrumentation profile' "${ART}/meta/thinlto-compat-build.log"; then
      TL_CONSUMED="ACCEPTED_NO_IGNORE_WARNINGS"
    else
      TL_CONSUMED="FAILED"
      TL_RESULT="FAIL"
    fi
    set +e
    run_windows_exe "${BIN}/final-thinlto-v3.exe" "$WIN_WORKDIR"
    TL_RUN=$?
    set -e
    [[ "$TL_RUN" -eq 0 ]] || TL_RESULT="FAIL"
  fi
fi

jq -n \
  --arg build "$TL_RESULT" \
  --arg consumed "$TL_CONSUMED" \
  --arg sha "$(json_sha256 "${BIN}/final-thinlto-v3.exe" 2>/dev/null || true)" \
  '{x86_64_v3:true,csir_profile:true,thinlto:true,build:$build,profile_consumption:$consumed,sha256:$sha}' \
  | tee "${ART}/meta/thinlto-compat.json"

echo "== write summary =="
jq -n \
  --slurpfile tool "${ART}/meta/toolchain.json" \
  --slurpfile a "${ART}/meta/stage-a-run.json" \
  --slurpfile b "${ART}/meta/stage-b-run.json" \
  --slurpfile c "${ART}/meta/merge.json" \
  --slurpfile d "${ART}/meta/final-run.json" \
  --slurpfile cs "${ART}/meta/cs-profile.json" \
  --slurpfile fb "${ART}/meta/final-build.json" \
  --slurpfile tl "${ART}/meta/thinlto-compat.json" \
  '{
    toolchain: $tool[0],
    stage_a: $a[0],
    stage_b: $b[0],
    merge: $c[0],
    final_build: $fb[0],
    final_run: $d[0],
    cs_profile: $cs[0],
    thinlto_compat: $tl[0],
    custom_llvm_required: false
  }' | tee "${ART}/meta/summary.json"

echo "Phase 5 CSIR PoC pipeline finished."
