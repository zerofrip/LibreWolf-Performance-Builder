#!/usr/bin/env bash
# Clone pinned bsys6 into work/bsys6.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

DEST="${1:-${ROOT}/work/bsys6}"
mkdir -p "$(dirname "$DEST")"

if [[ -d "$DEST/.git" ]]; then
  echo "Updating existing bsys6 clone at $DEST"
  git -C "$DEST" fetch --tags origin
  git -C "$DEST" fetch origin "${LWPB_BSYS6_REV}"
  git -C "$DEST" checkout --force "${LWPB_BSYS6_REV}"
else
  rm -rf "$DEST"
  # Full history not required, but the exact pinned commit must be fetchable.
  git clone "${LWPB_BSYS6_GIT}" "$DEST"
  git -C "$DEST" checkout --force "${LWPB_BSYS6_REV}"
fi

GOT="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$GOT" != "$LWPB_BSYS6_REV" ]]; then
  echo "ERROR: bsys6 HEAD $GOT != pinned $LWPB_BSYS6_REV" >&2
  exit 1
fi

echo "bsys6 ready at $DEST ($GOT)"
export LWPB_BSYS6_DIR="$DEST"
