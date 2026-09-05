#!/usr/bin/env bash
# Phase 6 Stage D: final LibreWolf with combined.profdata + v3 + ThinLTO.
# Exactly one C/C++ profile authority: combined.profdata (not windows.profdata).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

COMBINED="${1:-${LWPB_CSIR_COMBINED_PROFDATA:-${PROF_DIR}/combined.profdata}}"
require_nonempty "$COMBINED"
COMBINED_SHA="$(json_sha256 "$COMBINED")"
COMBINED_ABS="$(cd "$(dirname "$COMBINED")" && pwd)/$(basename "$COMBINED")"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR" \
  "${ROOT}/artifacts/logs" "${ROOT}/artifacts/probes" "$RUN_DIR"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""
export LWPB_BUILD_PHASE="6-csir-final"
export LWPB_CSIR_STAGE="D"
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
      "$mozconfig" "${META_DIR}/bsys6-build-package.log" "${LWPB_COMPILER_LOG}" \
      "${META_DIR}/v3-proof.json" || true
    bash "${ROOT}/scripts/prove-thinlto.sh" \
      "$mozconfig" "${META_DIR}/bsys6-build-package.log" "${LWPB_COMPILER_LOG}" \
      "${META_DIR}/thinlto-proof.json" || true
  fi
  write_stage_meta "${META_DIR}/stage-d-build.json" \
    --arg status "$STATUS" --arg run_id "$RUN_ID" --arg stage "D" \
    --arg duration_sec "$duration" \
    --arg artifact "${ARTIFACT}" --arg artifact_sha "$(json_sha256 "${ARTIFACT}")" \
    --arg combined_sha "$COMBINED_SHA" --arg combined_path "$COMBINED" \
    --arg source_rev "$LWPB_SOURCE_REV" \
    '{
      status:$status, run_id:$run_id, stage:$stage, duration_sec:$duration_sec,
      artifact:$artifact, artifact_sha256:$artifact_sha,
      combined_profdata:$combined_path, combined_sha256:$combined_sha, source_rev:$source_rev,
      requested:{
        cpp_profile_generate:false,
        cpp_profile_use:true,
        cpp_cs_profile_generate:false,
        thinlto:true,
        x86_64_v3:true,
        full_lto:false,
        rust_csir:false
      }
    }'
}
trap cleanup_meta EXIT

"${ROOT}/scripts/disk-report.sh" before-start
"${ROOT}/scripts/verify-thinlto-config.sh"
"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/probe-clang-v3.sh" "${ROOT}/artifacts/probes"
"${ROOT}/scripts/probe-rust-v3.sh" "${ROOT}/artifacts/probes"
"${ROOT}/scripts/probe-thinlto.sh" "${ROOT}/artifacts/probes"

export TARGET=windows ARCH=x86_64
export VERSION="${LWPB_FULL_VERSION}"
export FORGE_URL="${LWPB_FORGE_URL}" SOURCE_URL="${LWPB_SOURCE_URL}"
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

REAL_CLANG="$(command -v clang)"; REAL_CLANGXX="$(command -v clang++)"; REAL_RUSTC="$(command -v rustc)"
[[ -n "$REAL_CLANG" && -n "$REAL_CLANGXX" && -n "$REAL_RUSTC" ]] || exit 1
[[ -x /root/.mozbuild/clang/bin/clang ]] && REAL_CLANG=/root/.mozbuild/clang/bin/clang && REAL_CLANGXX=/root/.mozbuild/clang/bin/clang++
[[ -x /root/.cargo/bin/rustc ]] && REAL_RUSTC=/root/.cargo/bin/rustc

WRAPPER="${ROOT}/scripts/wrappers/compiler-log-wrapper.sh"
RUST_WRAPPER="${ROOT}/scripts/wrappers/rustc-log-wrapper.sh"
chmod +x "$WRAPPER" "$RUST_WRAPPER" "${ROOT}/scripts/csir-fulltree/"*.sh \
  "${ROOT}/scripts/prove-march-v3.sh" "${ROOT}/scripts/prove-thinlto.sh"

WRAP_BIN="${META_DIR}/wrap-bin"; mkdir -p "$WRAP_BIN"
REAL_CLANG_CL="${REAL_CLANG%/*}/clang-cl"
[[ -x "$REAL_CLANG_CL" ]] || exit 1

for kind_pair in "clang:${REAL_CLANG}:clang" "clang++:${REAL_CLANGXX}:clangxx" "clang-cl:${REAL_CLANG_CL}:clang-cl"; do
  name="${kind_pair%%:*}"; rest="${kind_pair#*:}"; real="${rest%%:*}"; kind="${rest#*:}"
  cat >"${WRAP_BIN}/${name}" <<EOF
#!/usr/bin/env bash
export LWPB_WRAPPER_KIND=${kind}
export LWPB_REAL_COMPILER="${real}"
export LWPB_COMPILER_LOG="${LWPB_COMPILER_LOG}"
exec "${WRAPPER}" "\$@"
EOF
  chmod +x "${WRAP_BIN}/${name}"
done
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
  cd "${LWPB_BSYS6_DIR}"; ./bsys6 source
) 2>&1 | tee "${META_DIR}/bsys6-source.log"

MOZCONFIG_PATH="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig"
MOZCONFIG_BACKUP="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig.backup"
require_file "$MOZCONFIG_BACKUP"

# Clean conflicting stage markers / generate / upstream profile lines from backup
tmp="$(mktemp)"
grep -Ev 'LWPB_PHASE6_CSIR_BASE_GEN|LWPB_PHASE6_CSIR_CS_GEN|LWPB_PHASE6_CSIR_FINAL|--enable-profile-generate|fcs-profile-generate' \
  "$MOZCONFIG_BACKUP" >"$tmp" || true
mv "$tmp" "$MOZCONFIG_BACKUP"
strip_upstream_profdata_use "$MOZCONFIG_BACKUP"

if ! grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    echo "# LWPB_CI_RESOURCE_GUARD"
    echo "mk_add_options MOZ_MAKE_FLAGS=\"${MOZ_MAKE_FLAGS:--j2}\""
  } >>"$MOZCONFIG_BACKUP"
fi
append_frag "$MOZCONFIG_BACKUP" "${ROOT}/configs/mozconfig.x86-64-v3.frag" 'LWPB_PHASE3_X86_64_V3'
append_frag "$MOZCONFIG_BACKUP" "${ROOT}/configs/mozconfig.thinlto.frag" 'LWPB_PHASE4_THINLTO'
{
  echo ""
  cat "${ROOT}/configs/mozconfig.csir-final.frag"
  echo "ac_add_options --enable-profile-use"
  echo "ac_add_options --with-pgo-profile-path=${COMBINED_ABS}"
} >>"$MOZCONFIG_BACKUP"

regenerate_mozconfig "${LWPB_BSYS6_DIR}" "$MOZCONFIG_PATH" \
  2>&1 | tee -a "${META_DIR}/bsys6-source.log"

grep -q 'LWPB_PHASE6_CSIR_FINAL' "$MOZCONFIG_PATH" || exit 1
grep -Eq -- '--enable-lto=thin' "$MOZCONFIG_PATH" || exit 1
grep -Fq -- "$COMBINED_ABS" "$MOZCONFIG_PATH" || exit 1
if grep -Eq -- '--enable-profile-generate|fcs-profile-generate' "$MOZCONFIG_PATH"; then
  echo "ERROR: Stage D must not generate profiles/CSIR" >&2
  exit 1
fi
if grep -Eq -- 'windows\.profdata' "$MOZCONFIG_PATH"; then
  echo "ERROR: dual-profile ambiguity with windows.profdata" >&2
  exit 1
fi
if grep -Eq -- '--enable-lto=.*full|--enable-lto=.*cross' "$MOZCONFIG_PATH"; then
  echo "ERROR: Full/cross LTO forbidden" >&2
  exit 1
fi

{
  echo "-> Effective Stage D mozconfig:"
  grep -E 'LWPB_|profile-|enable-lto|march=x86-64-v3|target-cpu|pgo-profile' "$MOZCONFIG_PATH" || true
} | tee "${META_DIR}/mozconfig-stage-d.txt"

"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/disk-report.sh" before-build
bash "${ROOT}/scripts/memory-report.sh" full memory-pre-build || true

(
  cd "${LWPB_BSYS6_DIR}"; ./bsys6 build package
) 2>&1 | tee "${META_DIR}/bsys6-build-package.log"

# Combined profile consumption evidence
grep -Fq -- "$COMBINED_ABS" "${META_DIR}/bsys6-build-package.log" \
  || grep -Fq -- "$(basename "$COMBINED")" "${LWPB_COMPILER_LOG}" \
  || grep -Eq -- 'fprofile-use' "${LWPB_COMPILER_LOG}" \
  || { echo "ERROR: combined profile consumption not evidenced" >&2; exit 1; }
# Stronger: path in configure/autoconf or compiler log
if ! grep -Fq -- "$COMBINED_ABS" "${META_DIR}/mozconfig-stage-d.txt" \
  && ! grep -Fq -- "$COMBINED_ABS" "${LWPB_COMPILER_LOG}" \
  && ! grep -Fq -- "$COMBINED_ABS" "${META_DIR}/bsys6-build-package.log"; then
  echo "ERROR: combined.profdata path not proven in build evidence" >&2
  exit 1
fi
# Record proof marker
echo "FINAL_COMBINED_PROFILE_CONSUMPTION=PROVEN path=${COMBINED_ABS} sha256=${COMBINED_SHA}" \
  | tee "${META_DIR}/combined-profile-consumption.txt"

if grep -Eq -- 'fcs-profile-generate' "${LWPB_COMPILER_LOG}"; then
  echo "ERROR: CSIR generate must be OFF in Stage D" >&2
  exit 1
fi

mapfile -t ZIPS < <(find "${LWPB_BSYS6_DIR}" "${ROOT}" "$WORKDIR" -maxdepth 3 -type f -name 'librewolf-*.zip' 2>/dev/null | sort -u)
[[ "${#ZIPS[@]}" -gt 0 ]] || exit 1
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
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/omni\.ja$' || exit 1
MZ_HDR="$(set +o pipefail; unzip -p "$ARTIFACT" librewolf/librewolf.exe 2>/dev/null | dd bs=2 count=1 2>/dev/null; true)"
[[ "$MZ_HDR" == $'MZ' ]] || exit 1

bash "${ROOT}/scripts/prove-march-v3.sh" \
  "$MOZCONFIG_PATH" "${META_DIR}/bsys6-build-package.log" "${LWPB_COMPILER_LOG}" \
  "${META_DIR}/v3-proof.json"
bash "${ROOT}/scripts/prove-thinlto.sh" \
  "$MOZCONFIG_PATH" "${META_DIR}/bsys6-build-package.log" "${LWPB_COMPILER_LOG}" \
  "${META_DIR}/thinlto-proof.json"

"${ROOT}/scripts/check-privacy-invariants.sh"
STATUS="ok"
echo "Stage D package complete: $ARTIFACT combined_sha=$COMBINED_SHA"
