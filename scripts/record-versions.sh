#!/usr/bin/env bash
# Record versions/ directory snapshot helper for CI results.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${ROOT}/artifacts/baseline-windows-metadata.json"
DEST="${ROOT}/versions/baseline-windows.json"

if [[ ! -f "$META" ]]; then
  echo "ERROR: missing $META" >&2
  exit 1
fi

mkdir -p "${ROOT}/versions"
cp -f "$META" "$DEST"
echo "Recorded $DEST"
