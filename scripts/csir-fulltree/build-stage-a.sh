#!/usr/bin/env bash
# Phase 6 Stage A: full-tree LibreWolf Windows base IR profile-generate build.
# Strips upstream windows.profdata profile-use. No ThinLTO (Firefox disables LTO
# under --enable-profile-generate). No CSIR. No Rust CSIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR" \
  "${ROOT}/artifacts/logs" "${ROOT}/artifacts/probes" "$RUN_DIR"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""
export LWPB_BUILD_PHASE="6-csir-base-gen"
export LWPB_CSIR_STAGE="A"
export LWPB_COMPILER_LOG="${META_DIR}/compiler-invocations.jsonl"
: >"${LWPB_COMPILER_LOG}"
echo "$RUN_ID" >"${ART}/CURRENT_RUN_ID"

stop_heartbeat() {
  if [[ -f "${ROOT}/artifacts/disk/heartbeat.pid" ]]; then
    kill "$(cat "${ROOT}/artifacts/disk/heartbeat.pid")" 2>/dev/null || true
    rm -f "${ROOT}/artifacts/disk/heartbeat.pid"
  fi
}

cleanup_meta() {
  stop_heartbeat
  bash "${ROOT}/scripts/memory-report.sh" full memory-after || true
  bash "${ROOT}/scripts/memory-report.sh" summary || true
  local end duration mozconfig=""
  end="$(date +%s)"
  duration="$((end - START_TS))"
  if [[ -n "${WORKDIR:-}" ]]; then
    mozconfig="${WORKDIR}/librewolf-${LWPB_FULL_VERSION:-}/mozconfig"
  fi
  if [[ -n "$mozconfig" && -f "$mozconfig" ]]; then
    bash "${ROOT}/scripts/prove-march-v3.sh" \
      "$mozconfig" \
      "${META_DIR}/bsys6-build-package.log" \
      "${LWPB_COMPILER_LOG}" \
      "${META_DIR}/v3-proof.json" || true
  fi
  write_stage_meta "${META_DIR}/stage-a-build.json" \
    --arg status "$STATUS" \
    --arg run_id "$RUN_ID" \
    --arg phase "$LWPB_BUILD_PHASE" \
    --arg stage "A" \
    --arg duration_sec "$duration" \
    --arg artifact "${ARTIFACT}" \
    --arg artifact_sha "$(json_sha256 "${ARTIFACT}")" \
    --arg source_rev "$LWPB_SOURCE_REV" \
    --argjson cpp_profile_generate_requested true \
    --argjson cpp_profile_use_requested false \
    --argjson cpp_cs_profile_generate_requested false \
    --argjson thinlto_requested false \
    '{
      status:$status, run_id:$run_id, phase:$phase, stage:$stage,
      duration_sec:$duration_sec, artifact:$artifact, artifact_sha256:$artifact_sha,
      source_rev:$source_rev,
      requested:{
        cpp_profile_generate:$cpp_profile_generate_requested,
        cpp_profile_use:$cpp_profile_use_requested,
        cpp_cs_profile_generate:$cpp_cs_profile_generate_requested,
        thinlto:$thinlto_requested
      }
    }'
}
trap cleanup_meta EXIT

"${ROOT}/scripts/disk-report.sh" before-start
"${ROOT}/scripts/check-privacy-invariants.sh"

"${ROOT}/scripts/probe-clang-v3.sh" "${ROOT}/artifacts/probes"
"${ROOT}/scripts/probe-rust-v3.sh" "${ROOT}/artifacts/probes"

export TARGET=windows
export ARCH=x86_64
export VERSION="${LWPB_FULL_VERSION}"
export FORGE_URL="${LWPB_FORGE_URL}"
export SOURCE_URL="${LWPB_SOURCE_URL}"
export WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
mkdir -p "$WORKDIR"

if [[ -d /root/.mozbuild/win-cross/vs ]]; then
  export HOME=/root
  export MOZBUILD=/root/.mozbuild
  export MOZBUILD_STATE_PATH=/root/.mozbuild
  export PATH="/root/.cargo/bin:/root/.mozbuild/clang/bin:${PATH}"
fi

unset LTO MOZ_PGO MOZ_PROFILE_GENERATE MOZ_PROFILE_USE || true
export LTO=false

# shellcheck source=../ci-resource-guard.sh
source "${ROOT}/scripts/ci-resource-guard.sh"

REAL_CLANG="$(command -v clang)"
REAL_CLANGXX="$(command -v clang++)"
REAL_RUSTC="$(command -v rustc)"
[[ -n "$REAL_CLANG" && -n "$REAL_CLANGXX" && -n "$REAL_RUSTC" ]] \
  || { echo "ERROR: clang/clang++/rustc required" >&2; exit 1; }
if [[ -x /root/.mozbuild/clang/bin/clang ]]; then
  REAL_CLANG=/root/.mozbuild/clang/bin/clang
  REAL_CLANGXX=/root/.mozbuild/clang/bin/clang++
fi
if [[ -x /root/.cargo/bin/rustc ]]; then
  REAL_RUSTC=/root/.cargo/bin/rustc
fi

WRAPPER="${ROOT}/scripts/wrappers/compiler-log-wrapper.sh"
RUST_WRAPPER="${ROOT}/scripts/wrappers/rustc-log-wrapper.sh"
chmod +x "$WRAPPER" "$RUST_WRAPPER" \
  "${ROOT}/scripts/prove-march-v3.sh" \
  "${ROOT}/scripts/csir-fulltree/"*.sh

WRAP_BIN="${META_DIR}/wrap-bin"
mkdir -p "$WRAP_BIN"
REAL_CLANG_CL="${REAL_CLANG%/*}/clang-cl"
[[ -x "$REAL_CLANG_CL" ]] || { echo "ERROR: clang-cl missing" >&2; exit 1; }

cat >"${WRAP_BIN}/clang" <<EOF
#!/usr/bin/env bash
export LWPB_WRAPPER_KIND=clang
export LWPB_REAL_COMPILER="${REAL_CLANG}"
export LWPB_COMPILER_LOG="${LWPB_COMPILER_LOG}"
exec "${WRAPPER}" "\$@"
EOF
cat >"${WRAP_BIN}/clang++" <<EOF
#!/usr/bin/env bash
export LWPB_WRAPPER_KIND=clangxx
export LWPB_REAL_COMPILER="${REAL_CLANGXX}"
export LWPB_COMPILER_LOG="${LWPB_COMPILER_LOG}"
exec "${WRAPPER}" "\$@"
EOF
cat >"${WRAP_BIN}/clang-cl" <<EOF
#!/usr/bin/env bash
export LWPB_WRAPPER_KIND=clang-cl
export LWPB_REAL_COMPILER="${REAL_CLANG_CL}"
export LWPB_COMPILER_LOG="${LWPB_COMPILER_LOG}"
exec "${WRAPPER}" "\$@"
EOF
chmod +x "${WRAP_BIN}/clang" "${WRAP_BIN}/clang++" "${WRAP_BIN}/clang-cl"
export PATH="${WRAP_BIN}:${PATH}"
export CC="${WRAP_BIN}/clang-cl"
export CXX="${WRAP_BIN}/clang-cl"
export HOST_CC="${WRAP_BIN}/clang"
export HOST_CXX="${WRAP_BIN}/clang++"
export RUSTC_WRAPPER="$RUST_WRAPPER"

"${ROOT}/scripts/probe-toolchain.sh" "${META_DIR}/toolchain-probe.txt"
"${ROOT}/scripts/fetch-bsys6.sh" "${ROOT}/work/bsys6"
export LWPB_BSYS6_DIR="${ROOT}/work/bsys6"
# Prevent bsys6 source.sh from re-injecting assets/windows.profdata (dual-profile).
disable_upstream_profdata_asset "${LWPB_BSYS6_DIR}"
TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"
"${ROOT}/scripts/fetch-source.sh" "${ROOT}/work"
export SOURCE_TAR="${LWPB_SOURCE_TAR:-${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz}"
require_file "$SOURCE_TAR"

BSYS6="${LWPB_BSYS6_DIR}/bsys6"
[[ -x "$BSYS6" ]] || { echo "ERROR: bsys6 missing" >&2; exit 1; }

echo "-> bsys6 source (Stage A, upstream profdata asset disabled)"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee "${META_DIR}/bsys6-source.log"

MOZCONFIG_PATH="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig"
MOZCONFIG_BACKUP="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig.backup"
require_file "$MOZCONFIG_PATH"
require_file "$MOZCONFIG_BACKUP"

strip_upstream_profdata_use "$MOZCONFIG_BACKUP"
strip_upstream_profdata_use "$MOZCONFIG_PATH"
if ! grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    echo "# LWPB_CI_RESOURCE_GUARD"
    echo "mk_add_options MOZ_MAKE_FLAGS=\"${MOZ_MAKE_FLAGS:--j2}\""
  } >>"$MOZCONFIG_BACKUP"
fi
append_frag "$MOZCONFIG_BACKUP" "${ROOT}/configs/mozconfig.x86-64-v3.frag" 'LWPB_PHASE3_X86_64_V3'
append_frag "$MOZCONFIG_BACKUP" "${ROOT}/configs/mozconfig.csir-base-gen.frag" 'LWPB_PHASE6_CSIR_BASE_GEN'
# Stage A must not request LTO (Firefox disables C/C++ LTO under profile-generate).
if grep -Eq -- '--enable-lto' "$MOZCONFIG_BACKUP"; then
  echo "ERROR: --enable-lto must not be in Stage A mozconfig.backup" >&2
  exit 1
fi

regenerate_mozconfig "${LWPB_BSYS6_DIR}" "$MOZCONFIG_PATH" \
  2>&1 | tee -a "${META_DIR}/bsys6-source.log"

grep -q 'LWPB_PHASE6_CSIR_BASE_GEN' "$MOZCONFIG_PATH" \
  || { echo "ERROR: Stage A frag missing" >&2; exit 1; }
grep -Eq -- '--enable-profile-generate' "$MOZCONFIG_PATH" \
  || { echo "ERROR: --enable-profile-generate missing" >&2; exit 1; }
if grep -Eq -- '--enable-profile-use|--with-pgo-profile-path=' "$MOZCONFIG_PATH"; then
  echo "ERROR: upstream profile-use must not remain in Stage A mozconfig" >&2
  exit 1
fi
if grep -Eq -- '--enable-lto' "$MOZCONFIG_PATH"; then
  echo "ERROR: LTO must not be requested in Stage A mozconfig" >&2
  exit 1
fi
[[ ! -f "${LWPB_BSYS6_DIR}/assets/windows.profdata" ]] \
  || { echo "ERROR: windows.profdata asset reappeared" >&2; exit 1; }

{
  echo "-> Effective Stage A mozconfig:"
  grep -E 'LWPB_|profile-generate|profile-use|enable-lto|march=x86-64-v3|target-cpu' \
    "$MOZCONFIG_PATH" || true
} | tee "${META_DIR}/mozconfig-stage-a.txt"

"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/disk-report.sh" before-build
bash "${ROOT}/scripts/memory-report.sh" full memory-pre-build || true

echo "-> bsys6 build package (Stage A base IR generate)"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 build package
) 2>&1 | tee "${META_DIR}/bsys6-build-package.log"

# Prove instrumentation from configure and/or target compiler invocations
INSTR_OK=0
if grep -Eq -- 'PROFILE_GEN|fprofile-generate|profile-generate' "${META_DIR}/bsys6-build-package.log"; then
  INSTR_OK=1
fi
if [[ -s "${LWPB_COMPILER_LOG}" ]] && grep -Eq -- 'fprofile-generate' "${LWPB_COMPILER_LOG}"; then
  INSTR_OK=1
fi
[[ "$INSTR_OK" -eq 1 ]] || { echo "ERROR: no effective profile-generate evidence" >&2; exit 1; }
# Must not see CSIR generate in Stage A
if grep -Eq -- 'fcs-profile-generate' "${LWPB_COMPILER_LOG}" "${META_DIR}/bsys6-build-package.log"; then
  echo "ERROR: CSIR generation must be OFF in Stage A" >&2
  exit 1
fi
# Dual-profile ambiguity must stay absent
if grep -Eq -- 'windows\.profdata' "${META_DIR}/mozconfig-stage-a.txt"; then
  echo "ERROR: windows.profdata referenced in Stage A mozconfig" >&2
  exit 1
fi

mapfile -t ZIPS < <(find "${LWPB_BSYS6_DIR}" "${ROOT}" "$WORKDIR" -maxdepth 3 -type f -name 'librewolf-*.zip' 2>/dev/null | sort -u)
[[ "${#ZIPS[@]}" -gt 0 ]] || { echo "ERROR: no package zip" >&2; exit 1; }
ARTIFACT_SRC=""
for z in "${ZIPS[@]}"; do
  case "$(basename "$z")" in
    librewolf-*-windows-x86_64-package.zip) ARTIFACT_SRC="$z"; break ;;
  esac
done
[[ -n "$ARTIFACT_SRC" ]] || ARTIFACT_SRC="${ZIPS[0]}"
ARTIFACT_NAME="$(basename "$ARTIFACT_SRC")"
ARTIFACT="${OUT_DIR}/${ARTIFACT_NAME}"
cp -f "$ARTIFACT_SRC" "$ARTIFACT"
cp -f "$ARTIFACT" "${ROOT}/out/${ARTIFACT_NAME}"
sha256sum "$ARTIFACT" | tee "${ARTIFACT}.sha256"

unzip -t "$ARTIFACT" >/dev/null
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/librewolf\.exe$' \
  || { echo "ERROR: librewolf.exe missing" >&2; exit 1; }
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/xul\.dll$' \
  || { echo "ERROR: xul.dll missing" >&2; exit 1; }
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/omni\.ja$' \
  || { echo "ERROR: omni.ja missing" >&2; exit 1; }
MZ_HDR="$(set +o pipefail
  unzip -p "$ARTIFACT" librewolf/librewolf.exe 2>/dev/null | dd bs=2 count=1 2>/dev/null
  true)"
[[ "$MZ_HDR" == $'MZ' ]] || { echo "ERROR: not PE" >&2; exit 1; }

bash "${ROOT}/scripts/prove-march-v3.sh" \
  "$MOZCONFIG_PATH" \
  "${META_DIR}/bsys6-build-package.log" \
  "${LWPB_COMPILER_LOG}" \
  "${META_DIR}/v3-proof.json"

"${ROOT}/scripts/check-privacy-invariants.sh"
STATUS="ok"
echo "Stage A package complete: $ARTIFACT (run $RUN_ID)"
