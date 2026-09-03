#!/usr/bin/env bash
# Clone pinned bsys6 into work/bsys6 (Codeberg authoritative for 155+).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

DEST="${1:-${ROOT}/work/bsys6}"
mkdir -p "$(dirname "$DEST")"

if [[ -d "$DEST/.git" ]]; then
  echo "Updating existing bsys6 clone at $DEST"
  git -C "$DEST" remote set-url origin "${LWPB_BSYS6_GIT}"
  git -C "$DEST" fetch --tags origin
  git -C "$DEST" fetch origin "${LWPB_BSYS6_REV}"
  git -C "$DEST" checkout --force "${LWPB_BSYS6_REV}"
else
  rm -rf "$DEST"
  git clone "${LWPB_BSYS6_GIT}" "$DEST"
  git -C "$DEST" checkout --force "${LWPB_BSYS6_REV}"
fi

GOT="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$GOT" != "$LWPB_BSYS6_REV" ]]; then
  echo "ERROR: bsys6 HEAD $GOT != pinned $LWPB_BSYS6_REV" >&2
  exit 1
fi

# windows.profdata / linux.profdata are Git LFS (~100MB+). Pointers alone break
# upstream profile-use injection in source.sh.
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  echo "-> Fetching Git LFS objects for bsys6"
  git -C "$DEST" lfs install --local >/dev/null
  git -C "$DEST" lfs pull
else
  echo "ERROR: git-lfs is required to fetch bsys6 assets/*.profdata" >&2
  exit 1
fi

# Sanity: profdata must not remain an LFS pointer for Windows builds
if [[ -f "$DEST/assets/windows.profdata" ]]; then
  if head -1 "$DEST/assets/windows.profdata" | grep -q 'git-lfs'; then
    echo "ERROR: assets/windows.profdata is still an LFS pointer after git lfs pull" >&2
    exit 1
  fi
fi

# Confirm Windows x64 triple at this pin
TARGET=windows ARCH=x86_64
# shellcheck disable=SC1091
source "$DEST/src/exports/target.sh"
echo "bsys6 ready at $DEST ($GOT); Windows x86_64 MOZ_TARGET=${MOZ_TARGET}"

export LWPB_BSYS6_DIR="$DEST"
