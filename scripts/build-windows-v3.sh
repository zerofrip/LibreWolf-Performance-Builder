#!/usr/bin/env bash
# Phase 3: Windows x64 LibreWolf with x86-64-v3 CPU baseline overlay.
# Preserves upstream PGO + Firefox rust.mk gkrust -Clto. No ThinLTO/CSIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR" \
  "${ROOT}/artifacts/logs" "${ROOT}/artifacts/probes"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""
HEARTBEAT_PID=""
export LWPB_BUILD_PHASE="3-x86-64-v3"
export LWPB_COMPILER_LOG="${ROOT}/artifacts/logs/compiler-invocations.jsonl"
: >"${LWPB_COMPILER_LOG}"

stop_heartbeat() {
  if [[ -f "${ROOT}/artifacts/disk/heartbeat.pid" ]]; then
    kill "$(cat "${ROOT}/artifacts/disk/heartbeat.pid")" 2>/dev/null || true
    rm -f "${ROOT}/artifacts/disk/heartbeat.pid"
  fi
  if [[ -n "${HEARTBEAT_PID}" ]]; then
    kill "${HEARTBEAT_PID}" 2>/dev/null || true
  fi
}

cleanup_meta() {
  local end duration
  stop_heartbeat
  bash "${ROOT}/scripts/memory-report.sh" full memory-after || true
  bash "${ROOT}/scripts/memory-report.sh" summary || true
  end="$(date +%s)"
  duration="$((end - START_TS))"
  local mozconfig=""
  if [[ -n "${WORKDIR:-}" ]]; then
    mozconfig="${WORKDIR}/librewolf-${LWPB_FULL_VERSION:-}/mozconfig"
  fi
  # Best-effort v3 proof (may fail if build failed early)
  if [[ -n "$mozconfig" && -f "$mozconfig" ]]; then
    bash "${ROOT}/scripts/prove-march-v3.sh" \
      "$mozconfig" \
      "${ROOT}/artifacts/logs/bsys6-build-package.log" \
      "${LWPB_COMPILER_LOG}" \
      "${ROOT}/artifacts/v3-proof.json" || true
  fi
  "${ROOT}/scripts/write-build-metadata.sh" \
    "${ROOT}/artifacts/v3-windows-metadata.json" \
    "$STATUS" \
    "$duration" \
    "$ARTIFACT" \
    "${mozconfig}" \
    "${ROOT}/artifacts/logs/bsys6-build-package.log" || true
}
trap cleanup_meta EXIT

"${ROOT}/scripts/disk-report.sh" before-start
"${ROOT}/scripts/verify-v3-config.sh"
"${ROOT}/scripts/check-privacy-invariants.sh"

# Mandatory compiler probes (exact image toolchain when present)
"${ROOT}/scripts/probe-clang-v3.sh" "${ROOT}/artifacts/probes"
"${ROOT}/scripts/probe-rust-v3.sh" "${ROOT}/artifacts/probes"

# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

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
  echo "-> Using image toolchain MOZBUILD=${MOZBUILD} HOME=${HOME}"
fi

# Forbid overlay LTO / extra PGO env; upstream profile-use still via bsys6 assets
unset LTO MOZ_PGO MOZ_PROFILE_GENERATE MOZ_PROFILE_USE || true

# shellcheck source=ci-resource-guard.sh
source "${ROOT}/scripts/ci-resource-guard.sh"

# Install compiler logging wrappers on PATH (must be named clang/clang++).
# Do NOT set CC=/path/to/*.sh — Firefox configure rejects non-clang basenames
# ("Unknown compiler or compiler not supported", run 33927389796).
REAL_CLANG="$(command -v clang)"
REAL_CLANGXX="$(command -v clang++)"
REAL_RUSTC="$(command -v rustc)"
[[ -n "$REAL_CLANG" && -n "$REAL_CLANGXX" && -n "$REAL_RUSTC" ]] \
  || { echo "ERROR: clang/clang++/rustc required" >&2; exit 1; }

# Prefer image clang as the real backend even after PATH wrap
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
  "${ROOT}/scripts/probe-clang-v3.sh" "${ROOT}/scripts/probe-rust-v3.sh" \
  "${ROOT}/scripts/prove-march-v3.sh" "${ROOT}/scripts/verify-v3-config.sh" \
  "${ROOT}/scripts/check-privacy-invariants.sh"

WRAP_BIN="${ROOT}/artifacts/logs/wrap-bin"
mkdir -p "$WRAP_BIN"
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
chmod +x "${WRAP_BIN}/clang" "${WRAP_BIN}/clang++"
# Prepend wrap-bin so configure resolves basename "clang"
export PATH="${WRAP_BIN}:${PATH}"
unset CC CXX || true
export RUSTC_WRAPPER="$RUST_WRAPPER"

"${ROOT}/scripts/probe-toolchain.sh" "${ROOT}/artifacts/toolchain-probe.txt"

"${ROOT}/scripts/fetch-bsys6.sh" "${ROOT}/work/bsys6"
export LWPB_BSYS6_DIR="${ROOT}/work/bsys6"

TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"

"${ROOT}/scripts/fetch-source.sh" "${ROOT}/work"
export SOURCE_TAR="${LWPB_SOURCE_TAR:-${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz}"
[[ -f "$SOURCE_TAR" ]] || { echo "ERROR: missing SOURCE_TAR $SOURCE_TAR" >&2; exit 1; }

"${ROOT}/scripts/disk-report.sh" after-source-fetch

BSYS6="${LWPB_BSYS6_DIR}/bsys6"
[[ -x "$BSYS6" ]] || { echo "ERROR: bsys6 launcher missing at $BSYS6" >&2; exit 1; }

echo "-> Preparing source (bsys6 source) for Phase 3 x86-64-v3"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee "${ROOT}/artifacts/logs/bsys6-source.log"

MOZCONFIG_PATH="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig"
MOZCONFIG_BACKUP="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig.backup"
[[ -f "$MOZCONFIG_PATH" ]] || { echo "ERROR: mozconfig missing at $MOZCONFIG_PATH" >&2; exit 1; }
[[ -f "$MOZCONFIG_BACKUP" ]] || { echo "ERROR: mozconfig.backup missing at $MOZCONFIG_BACKUP" >&2; exit 1; }

grep -E '^ac_add_options --target=' "$MOZCONFIG_PATH" | tee "${ROOT}/artifacts/generated-target.txt"
grep -F 'x86_64-pc-windows-msvc' "${ROOT}/artifacts/generated-target.txt" \
  || { echo "ERROR: expected x86_64-pc-windows-msvc" >&2; exit 1; }

# Persist CI parallelism + Phase 3 v3 frag into mozconfig.backup
if ! grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    echo "# LWPB_CI_RESOURCE_GUARD: runner memory/CPU cap (not an optimization)"
    echo "mk_add_options MOZ_MAKE_FLAGS=\"${MOZ_MAKE_FLAGS:--j2}\""
  } >>"$MOZCONFIG_BACKUP"
fi
if ! grep -q 'LWPB_PHASE3_X86_64_V3' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    cat "${ROOT}/configs/mozconfig.x86-64-v3.frag"
  } >>"$MOZCONFIG_BACKUP"
fi

rm -f "${MOZCONFIG_PATH}.hash"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee -a "${ROOT}/artifacts/logs/bsys6-source.log"

grep -q 'LWPB_PHASE3_X86_64_V3' "$MOZCONFIG_PATH" \
  || { echo "ERROR: Phase 3 v3 frag missing from regenerated mozconfig" >&2; exit 1; }
grep -Eq -- '-march=x86-64-v3' "$MOZCONFIG_PATH" \
  || { echo "ERROR: -march=x86-64-v3 missing from mozconfig" >&2; exit 1; }
grep -Eq -- 'target-cpu=x86-64-v3' "$MOZCONFIG_PATH" \
  || { echo "ERROR: target-cpu=x86-64-v3 missing from mozconfig" >&2; exit 1; }

{
  echo "-> Effective mozconfig Phase 3 lines:"
  grep -E 'LWPB_|MOZ_MAKE_FLAGS|--target=|march=x86-64-v3|target-cpu=x86-64-v3|CFLAGS|CXXFLAGS|RUSTFLAGS' \
    "$MOZCONFIG_PATH" || true
} | tee "${ROOT}/artifacts/logs/mozconfig-resource.txt"

"${ROOT}/scripts/check-privacy-invariants.sh"

"${ROOT}/scripts/disk-report.sh" before-build

echo "-> Running bsys6 build package (Phase 3 x86-64-v3)"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 build package
) 2>&1 | tee "${ROOT}/artifacts/logs/bsys6-build-package.log"

"${ROOT}/scripts/disk-report.sh" after-package

mapfile -t ZIPS < <(find "${LWPB_BSYS6_DIR}" "${ROOT}" "$WORKDIR" -maxdepth 3 -type f -name 'librewolf-*.zip' 2>/dev/null | sort -u)
if [[ "${#ZIPS[@]}" -eq 0 ]]; then
  echo "ERROR: no librewolf-*.zip artifact found after package" >&2
  exit 1
fi

ARTIFACT_SRC="${ZIPS[0]}"
ARTIFACT_NAME="$(basename "$ARTIFACT_SRC")"
ARTIFACT="${ROOT}/out/${ARTIFACT_NAME}"
cp -f "$ARTIFACT_SRC" "$ARTIFACT"
sha256sum "$ARTIFACT" | tee "${ARTIFACT}.sha256"

# Structural package checks
unzip -t "$ARTIFACT" >/dev/null
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/librewolf\.exe$' \
  || { echo "ERROR: librewolf.exe missing" >&2; exit 1; }
unzip -p "$ARTIFACT" librewolf/librewolf.exe | head -c 2 | grep -q $'MZ' \
  || { echo "ERROR: librewolf.exe is not PE(MZ)" >&2; exit 1; }
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/xul\.dll$' \
  || { echo "ERROR: xul.dll missing" >&2; exit 1; }
unzip -l "$ARTIFACT" | grep -Eq 'librewolf/omni\.ja$' \
  || { echo "ERROR: omni.ja missing" >&2; exit 1; }

"${ROOT}/scripts/prove-march-v3.sh" \
  "$MOZCONFIG_PATH" \
  "${ROOT}/artifacts/logs/bsys6-build-package.log" \
  "${LWPB_COMPILER_LOG}" \
  "${ROOT}/artifacts/v3-proof.json"

"${ROOT}/scripts/check-privacy-invariants.sh"
"${ROOT}/scripts/verify-v3-config.sh"
TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"

STATUS="ok"
echo "Phase 3 x86-64-v3 package complete: $ARTIFACT"
