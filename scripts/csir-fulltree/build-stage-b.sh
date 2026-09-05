#!/usr/bin/env bash
# Phase 6 Stage B: full-tree base profile-use + C/C++ CSIR generation build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

BASE_PROF="${1:-${LWPB_CSIR_BASE_PROFDATA:-${PROF_DIR}/base.profdata}}"
require_nonempty "$BASE_PROF"
BASE_SHA="$(json_sha256 "$BASE_PROF")"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR" \
  "${ROOT}/artifacts/logs" "${ROOT}/artifacts/probes" "$RUN_DIR" "${PROF_DIR}/cs-gen"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""
export LWPB_BUILD_PHASE="6-csir-cs-gen"
export LWPB_CSIR_STAGE="B"
export LWPB_COMPILER_LOG="${META_DIR}/compiler-invocations.jsonl"
: >"${LWPB_COMPILER_LOG}"
echo "$RUN_ID" >"${ART}/CURRENT_RUN_ID"
CS_GEN_DIR="${PROF_DIR}/cs-gen"
mkdir -p "$CS_GEN_DIR"

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
  write_stage_meta "${META_DIR}/stage-b-build.json" \
    --arg status "$STATUS" \
    --arg run_id "$RUN_ID" \
    --arg stage "B" \
    --arg duration_sec "$duration" \
    --arg artifact "${ARTIFACT}" \
    --arg artifact_sha "$(json_sha256 "${ARTIFACT}")" \
    --arg base_sha "$BASE_SHA" \
    --arg base_path "$BASE_PROF" \
    --arg source_rev "$LWPB_SOURCE_REV" \
    '{
      status:$status, run_id:$run_id, stage:$stage, duration_sec:$duration_sec,
      artifact:$artifact, artifact_sha256:$artifact_sha,
      base_profdata:$base_path, base_sha256:$base_sha, source_rev:$source_rev,
      requested:{
        cpp_profile_generate:false,
        cpp_profile_use:true,
        cpp_cs_profile_generate:true,
        thinlto:false
      }
    }'
}
trap cleanup_meta EXIT

"${ROOT}/scripts/disk-report.sh" before-start
"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/probe-clang-v3.sh" "${ROOT}/artifacts/probes"
"${ROOT}/scripts/probe-rust-v3.sh" "${ROOT}/artifacts/probes"

export TARGET=windows ARCH=x86_64
export VERSION="${LWPB_FULL_VERSION}"
export FORGE_URL="${LWPB_FORGE_URL}"
export SOURCE_URL="${LWPB_SOURCE_URL}"
export WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
mkdir -p "$WORKDIR"

if [[ -d /root/.mozbuild/win-cross/vs ]]; then
  export HOME=/root MOZBUILD=/root/.mozbuild MOZBUILD_STATE_PATH=/root/.mozbuild
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
if [[ -x /root/.cargo/bin/rustc ]]; then REAL_RUSTC=/root/.cargo/bin/rustc; fi

WRAPPER="${ROOT}/scripts/wrappers/compiler-log-wrapper.sh"
RUST_WRAPPER="${ROOT}/scripts/wrappers/rustc-log-wrapper.sh"
chmod +x "$WRAPPER" "$RUST_WRAPPER" "${ROOT}/scripts/csir-fulltree/"*.sh \
  "${ROOT}/scripts/prove-march-v3.sh"

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
export CC="${WRAP_BIN}/clang-cl" CXX="${WRAP_BIN}/clang-cl"
export HOST_CC="${WRAP_BIN}/clang" HOST_CXX="${WRAP_BIN}/clang++"
export RUSTC_WRAPPER="$RUST_WRAPPER"

"${ROOT}/scripts/probe-toolchain.sh" "${META_DIR}/toolchain-probe.txt"
"${ROOT}/scripts/fetch-bsys6.sh" "${ROOT}/work/bsys6"
export LWPB_BSYS6_DIR="${ROOT}/work/bsys6"
disable_upstream_profdata_asset "${LWPB_BSYS6_DIR}"
TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"
"${ROOT}/scripts/fetch-source.sh" "${ROOT}/work"
export SOURCE_TAR="${LWPB_SOURCE_TAR:-${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz}"
require_file "$SOURCE_TAR"

(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee "${META_DIR}/bsys6-source.log"

MOZCONFIG_PATH="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig"
MOZCONFIG_BACKUP="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig.backup"
require_file "$MOZCONFIG_BACKUP"

if ! grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    echo "# LWPB_CI_RESOURCE_GUARD"
    echo "mk_add_options MOZ_MAKE_FLAGS=\"${MOZ_MAKE_FLAGS:--j2}\""
  } >>"$MOZCONFIG_BACKUP"
fi
append_frag "$MOZCONFIG_BACKUP" "${ROOT}/configs/mozconfig.x86-64-v3.frag" 'LWPB_PHASE3_X86_64_V3'
bash "${ROOT}/scripts/csir-fulltree/apply-stage-b-mozconfig.sh" \
  "$MOZCONFIG_BACKUP" "$BASE_PROF" "$CS_GEN_DIR"

regenerate_mozconfig "${LWPB_BSYS6_DIR}" "$MOZCONFIG_PATH" \
  2>&1 | tee -a "${META_DIR}/bsys6-source.log"

grep -q 'LWPB_PHASE6_CSIR_CS_GEN' "$MOZCONFIG_PATH" \
  || { echo "ERROR: Stage B marker missing" >&2; exit 1; }
grep -Eq -- '--enable-profile-use' "$MOZCONFIG_PATH" \
  || { echo "ERROR: profile-use missing" >&2; exit 1; }
grep -Fq -- "$(cd "$(dirname "$BASE_PROF")" && pwd)/$(basename "$BASE_PROF")" "$MOZCONFIG_PATH" \
  || { echo "ERROR: base.profdata path missing from mozconfig" >&2; exit 1; }
if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-profile-generate' "$MOZCONFIG_PATH"; then
  echo "ERROR: profile-generate must be OFF in Stage B" >&2
  grep -n 'profile-generate' "$MOZCONFIG_PATH" >&2 || true
  exit 1
fi
# Comments mentioning profile-generate are allowed; only active ac_add_options count.
if grep -Eq -- 'windows\.profdata' "$MOZCONFIG_PATH"; then
  echo "ERROR: upstream windows.profdata must not appear in Stage B" >&2
  exit 1
fi
grep -Eq -- 'fcs-profile-generate' "$MOZCONFIG_PATH" \
  || { echo "ERROR: CSIR generate flag missing from mozconfig" >&2; exit 1; }

{
  echo "-> Effective Stage B mozconfig:"
  grep -E 'LWPB_|profile-|fcs-profile|enable-lto|march=x86-64-v3|target-cpu|pgo-profile' \
    "$MOZCONFIG_PATH" || true
} | tee "${META_DIR}/mozconfig-stage-b.txt"

"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/disk-report.sh" before-build
bash "${ROOT}/scripts/memory-report.sh" full memory-pre-build || true

echo "-> bsys6 build package (Stage B CSIR generate)"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 build package
) 2>&1 | tee "${META_DIR}/bsys6-build-package.log"

# Hard gates on effective flags
grep -Eq -- 'fprofile-use|profile-use' "${LWPB_COMPILER_LOG}" "${META_DIR}/bsys6-build-package.log" \
  || { echo "ERROR: no evidence of profile-use" >&2; exit 1; }
grep -Eq -- 'fcs-profile-generate' "${LWPB_COMPILER_LOG}" "${META_DIR}/mozconfig-stage-b.txt" \
  || { echo "ERROR: no evidence of CSIR generate" >&2; exit 1; }
# Must NOT also have base IR generate on same target compiles
if grep -Eq -- 'fprofile-generate' "${LWPB_COMPILER_LOG}"; then
  # Allow false positives only if solely CS path — reject any -fprofile-generate without fcs
  if grep -E -- 'fprofile-generate' "${LWPB_COMPILER_LOG}" | grep -Ev 'fcs-profile-generate' | grep -q .; then
    echo "ERROR: -fprofile-generate coexisted with Stage B (forbidden)" >&2
    grep -E -- 'fprofile-generate' "${LWPB_COMPILER_LOG}" | head -20 >&2
    exit 1
  fi
fi

# Profile mismatch classification
DIAG="${META_DIR}/stage-b-profile-diagnostics.txt"
: >"$DIAG"
set +e
grep -Ei 'profile data may be out of date|function control flow change detected|hash mismatch|profile ignored|malformed profile|no profile data available|coverage mismatch' \
  "${META_DIR}/bsys6-build-package.log" "${LWPB_COMPILER_LOG}" >>"$DIAG"
set -e
if grep -Eiq 'malformed profile|no profile data available' "$DIAG"; then
  echo "ERROR: fatal profile diagnostics" >&2
  cat "$DIAG" >&2
  exit 1
fi
if grep -Eiq 'function control flow change detected|hash mismatch' "$DIAG"; then
  echo "ERROR: material CFG/hash mismatch vs base.profdata" >&2
  cat "$DIAG" >&2
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
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/librewolf\.exe$' || exit 1
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/xul\.dll$' || exit 1
MZ_HDR="$(set +o pipefail; unzip -p "$ARTIFACT" librewolf/librewolf.exe 2>/dev/null | dd bs=2 count=1 2>/dev/null; true)"
[[ "$MZ_HDR" == $'MZ' ]] || exit 1

bash "${ROOT}/scripts/prove-march-v3.sh" \
  "$MOZCONFIG_PATH" \
  "${META_DIR}/bsys6-build-package.log" \
  "${LWPB_COMPILER_LOG}" \
  "${META_DIR}/v3-proof.json"

"${ROOT}/scripts/check-privacy-invariants.sh"
STATUS="ok"
echo "Stage B package complete: $ARTIFACT base_sha=$BASE_SHA"

