#!/usr/bin/env bash
# Download pinned LibreWolf source tarball and verify SHA-256.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

OUT_DIR="${1:-${ROOT}/work}"
mkdir -p "$OUT_DIR"
TAR="${OUT_DIR}/librewolf-${LWPB_FULL_VERSION}.source.tar.gz"

if [[ -f "$TAR" ]]; then
  GOT_SHA="$(sha256sum "$TAR" | awk '{print $1}')"
  if [[ "$GOT_SHA" == "$LWPB_SOURCE_SHA256" ]]; then
    echo "Reusing existing source tarball $TAR"
    echo "${GOT_SHA}  $(basename "$TAR")" | tee "${TAR}.sha256"
    export LWPB_SOURCE_TAR="$TAR"
    exit 0
  fi
  echo "Existing tarball checksum mismatch; re-downloading"
  rm -f "$TAR"
fi

echo "Fetching ${LWPB_SOURCE_URL}"
curl -fL --retry 3 --retry-delay 2 -o "$TAR" "$LWPB_SOURCE_URL"

GOT_SHA="$(sha256sum "$TAR" | awk '{print $1}')"
if [[ "$GOT_SHA" != "$LWPB_SOURCE_SHA256" ]]; then
  echo "ERROR: SHA-256 mismatch for $TAR" >&2
  echo "  expected ${LWPB_SOURCE_SHA256}" >&2
  echo "  got      ${GOT_SHA}" >&2
  exit 1
fi

echo "${GOT_SHA}  $(basename "$TAR")" | tee "${TAR}.sha256"
echo "Source tarball OK: $TAR"
echo "  sha256=${GOT_SHA}"
export LWPB_SOURCE_TAR="$TAR"
