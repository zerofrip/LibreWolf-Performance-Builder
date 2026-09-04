#!/usr/bin/env bash
# Phase 2: upstream-equivalent Windows x64 LibreWolf build via pinned bsys6.
# No OUR optimization overlays (v3 / CSIR / overlay LTO). Upstream may still
# enable profile-use (windows.profdata) and Firefox default gkrust -Clto.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR" "${ROOT}/artifacts/logs"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""
HEARTBEAT_PID=""

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
  # Post-failure / post-success memory + cgroup snapshot (best-effort).
  bash "${ROOT}/scripts/memory-report.sh" full memory-after || true
  bash "${ROOT}/scripts/memory-report.sh" summary || true
  end="$(date +%s)"
  duration="$((end - START_TS))"
  local mozconfig=""
  if [[ -n "${WORKDIR:-}" ]]; then
    mozconfig="${WORKDIR}/librewolf-${LWPB_FULL_VERSION:-}/mozconfig"
  fi
  "${ROOT}/scripts/write-build-metadata.sh" \
    "${ROOT}/artifacts/baseline-windows-metadata.json" \
    "$STATUS" \
    "$duration" \
    "$ARTIFACT" \
    "${mozconfig}" \
    "${ROOT}/artifacts/logs/bsys6-build-package.log" || true
}
trap cleanup_meta EXIT

"${ROOT}/scripts/disk-report.sh" before-start
"${ROOT}/scripts/verify-baseline-config.sh"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

# Hard requirements for Phase 2 topology
export TARGET=windows
export ARCH=x86_64
export VERSION="${LWPB_FULL_VERSION}"
export FORGE_URL="${LWPB_FORGE_URL}"
export SOURCE_URL="${LWPB_SOURCE_URL}"
export WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
mkdir -p "$WORKDIR"

# Prefer the bsys6 Windows image toolchain layout when present.
# GitHub Actions container jobs often set HOME=/github/home, which would make
# mozconfig's WINSYSROOT=$MOZBUILD/win-cross/vs miss /root/.mozbuild.
if [[ -d /root/.mozbuild/win-cross/vs ]]; then
  export HOME=/root
  export MOZBUILD=/root/.mozbuild
  export MOZBUILD_STATE_PATH=/root/.mozbuild
  export PATH="/root/.cargo/bin:/root/.mozbuild/clang/bin:${PATH}"
  echo "-> Using image toolchain MOZBUILD=${MOZBUILD} HOME=${HOME}"
fi

# Refuse optimization env even if caller exports later
unset LTO MOZ_PGO MOZ_PROFILE_GENERATE MOZ_PROFILE_USE || true

# CI resource guard (parallelism cap + heartbeat). Not an optimization overlay.
# shellcheck source=ci-resource-guard.sh
source "${ROOT}/scripts/ci-resource-guard.sh"

"${ROOT}/scripts/probe-toolchain.sh" "${ROOT}/artifacts/toolchain-probe.txt"

"${ROOT}/scripts/fetch-bsys6.sh" "${ROOT}/work/bsys6"
export LWPB_BSYS6_DIR="${ROOT}/work/bsys6"

# Fail before mach if obsolete mingw32 triple would be generated
TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"

"${ROOT}/scripts/fetch-source.sh" "${ROOT}/work"
export SOURCE_TAR="${LWPB_SOURCE_TAR:-${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz}"
[[ -f "$SOURCE_TAR" ]] || { echo "ERROR: missing SOURCE_TAR $SOURCE_TAR" >&2; exit 1; }

"${ROOT}/scripts/disk-report.sh" after-source-fetch

BSYS6="${LWPB_BSYS6_DIR}/bsys6"
[[ -x "$BSYS6" ]] || { echo "ERROR: bsys6 launcher missing at $BSYS6" >&2; exit 1; }

echo "-> Preparing source (bsys6 source)"
echo "-> FORGE_URL=${FORGE_URL}"
echo "-> SOURCE_TAR=${SOURCE_TAR}"
echo "-> WORKDIR=${WORKDIR}"
echo "-> Expected MOZ_TARGET=${LWPB_WINDOWS_TARGET_X64}"
echo "-> MOZ_MAKE_FLAGS=${MOZ_MAKE_FLAGS:-}"

export SOURCE_TAR
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee "${ROOT}/artifacts/logs/bsys6-source.log"

MOZCONFIG_PATH="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig"
MOZCONFIG_BACKUP="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig.backup"
[[ -f "$MOZCONFIG_PATH" ]] || { echo "ERROR: mozconfig missing at $MOZCONFIG_PATH" >&2; exit 1; }
[[ -f "$MOZCONFIG_BACKUP" ]] || { echo "ERROR: mozconfig.backup missing at $MOZCONFIG_BACKUP" >&2; exit 1; }

# Record effective target before build
grep -E '^ac_add_options --target=' "$MOZCONFIG_PATH" | tee "${ROOT}/artifacts/generated-target.txt"
if grep -E 'mingw32|mingw64' "${ROOT}/artifacts/generated-target.txt"; then
  echo "ERROR: obsolete mingw triple in mozconfig" >&2
  exit 1
fi
grep -F 'x86_64-pc-windows-msvc' "${ROOT}/artifacts/generated-target.txt" \
  || { echo "ERROR: expected x86_64-pc-windows-msvc in mozconfig" >&2; exit 1; }

# Persist CI parallelism in mozconfig.backup so bsys6 source.sh regenerations keep it.
if ! grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_BACKUP"; then
  {
    echo ""
    echo "# LWPB_CI_RESOURCE_GUARD: GitHub-hosted runner memory/CPU cap (not an optimization)"
    echo "mk_add_options MOZ_MAKE_FLAGS=\"${MOZ_MAKE_FLAGS:--j2}\""
  } >>"$MOZCONFIG_BACKUP"
fi
# Force mozconfig regenerate from backup + windows.mozconfig + our guard.
rm -f "${MOZCONFIG_PATH}.hash"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 source
) 2>&1 | tee -a "${ROOT}/artifacts/logs/bsys6-source.log"

grep -q 'LWPB_CI_RESOURCE_GUARD' "$MOZCONFIG_PATH" \
  || { echo "ERROR: CI resource guard missing from regenerated mozconfig" >&2; exit 1; }
echo "-> Effective mozconfig resource lines:" | tee "${ROOT}/artifacts/logs/mozconfig-resource.txt"
grep -E 'MOZ_MAKE_FLAGS|LWPB_CI_RESOURCE|--target=' "$MOZCONFIG_PATH" \
  | tee -a "${ROOT}/artifacts/logs/mozconfig-resource.txt"

"${ROOT}/scripts/disk-report.sh" before-build

echo "-> Running bsys6 build package (TARGET=${TARGET} ARCH=${ARCH} VERSION=${VERSION})"
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 build package
) 2>&1 | tee "${ROOT}/artifacts/logs/bsys6-build-package.log"

"${ROOT}/scripts/disk-report.sh" after-package

# Collect zip artifact from bsys6 CWD / WORKDIR patterns
mapfile -t ZIPS < <(find "${LWPB_BSYS6_DIR}" "${ROOT}" "$WORKDIR" -maxdepth 3 -type f -name 'librewolf-*.zip' 2>/dev/null | sort -u)
if [[ "${#ZIPS[@]}" -eq 0 ]]; then
  echo "ERROR: no librewolf-*.zip artifact found after package" >&2
  find "${LWPB_BSYS6_DIR}" "${ROOT}/out" -maxdepth 4 -type f 2>/dev/null | head -100 >&2 || true
  exit 1
fi

ARTIFACT_SRC="${ZIPS[0]}"
ARTIFACT_NAME="$(basename "$ARTIFACT_SRC")"
ARTIFACT="${ROOT}/out/${ARTIFACT_NAME}"
cp -f "$ARTIFACT_SRC" "$ARTIFACT"
sha256sum "$ARTIFACT" | tee "${ARTIFACT}.sha256"

# Refresh generated-target evidence after build
grep -E '^ac_add_options --target=' "$MOZCONFIG_PATH" \
  | tee "${ROOT}/artifacts/generated-target.txt" || true

"${ROOT}/scripts/verify-baseline-config.sh"
TARGET=windows ARCH=x86_64 "${ROOT}/scripts/verify-windows-target.sh"

STATUS="ok"
echo "Phase 2 baseline package complete: $ARTIFACT"

