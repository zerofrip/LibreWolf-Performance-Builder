#!/usr/bin/env bash
# Phase 2: upstream-equivalent Windows x64 LibreWolf build via pinned bsys6.
# No LTO / PGO / x86-64-v3 overlays. Fail loudly on mismatches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
mkdir -p "${ROOT}/artifacts" "${ROOT}/work" "${ROOT}/out" "$DISK_REPORT_DIR"

START_TS="$(date +%s)"
STATUS="failed"
ARTIFACT=""

cleanup_meta() {
  local end duration
  end="$(date +%s)"
  duration="$((end - START_TS))"
  "${ROOT}/scripts/write-build-metadata.sh" \
    "${ROOT}/artifacts/baseline-windows-metadata.json" \
    "$STATUS" \
    "$duration" \
    "$ARTIFACT" || true
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

# Refuse optimization env even if caller exports later
unset LTO MOZ_PGO MOZ_PROFILE_GENERATE MOZ_PROFILE_USE || true

"${ROOT}/scripts/fetch-bsys6.sh" "${ROOT}/work/bsys6"
# shellcheck source=fetch-bsys6.sh
# LWPB_BSYS6_DIR set by fetch script when sourced; re-export from known path:
export LWPB_BSYS6_DIR="${ROOT}/work/bsys6"

"${ROOT}/scripts/fetch-source.sh" "${ROOT}/work"
export SOURCE_TAR="${LWPB_SOURCE_TAR:-${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz}"
[[ -f "$SOURCE_TAR" ]] || { echo "ERROR: missing SOURCE_TAR $SOURCE_TAR" >&2; exit 1; }

"${ROOT}/scripts/disk-report.sh" after-source-fetch

BSYS6="${LWPB_BSYS6_DIR}/bsys6"
[[ -x "$BSYS6" ]] || { echo "ERROR: bsys6 launcher missing at $BSYS6" >&2; exit 1; }

echo "-> Running bsys6 package (TARGET=${TARGET} ARCH=${ARCH} VERSION=${VERSION})"
echo "-> FORGE_URL=${FORGE_URL}"
echo "-> SOURCE_TAR=${SOURCE_TAR}"
echo "-> WORKDIR=${WORKDIR}"

# Use absolute SOURCE_TAR so bsys6 skips broken default package host logic
export SOURCE_TAR
(
  cd "${LWPB_BSYS6_DIR}"
  ./bsys6 package
)

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

# Double-check we did not accidentally enable LTO via env mid-build
"${ROOT}/scripts/verify-baseline-config.sh"

STATUS="ok"
echo "Phase 2 baseline package complete: $ARTIFACT"
