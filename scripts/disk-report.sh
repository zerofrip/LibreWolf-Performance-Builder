#!/usr/bin/env bash
# Report disk usage at a named build stage.
set -euo pipefail

STAGE="${1:-unknown}"
OUT_DIR="${DISK_REPORT_DIR:-${GITHUB_WORKSPACE:-.}/artifacts/disk}"
mkdir -p "$OUT_DIR"

{
  echo "=== disk-report stage=${STAGE} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  df -h
  echo
  df -h . 2>/dev/null || true
  echo
  if command -v du >/dev/null 2>&1; then
    echo "--- du (top-level work paths) ---"
    for p in \
      "${WORKDIR:-}" \
      "${HOME}/.mozbuild" \
      "${GITHUB_WORKSPACE:-.}/work" \
      "${GITHUB_WORKSPACE:-.}/out" \
      "${GITHUB_WORKSPACE:-.}/artifacts"
    do
      if [[ -n "$p" && -e "$p" ]]; then
        du -sh "$p" 2>/dev/null || true
      fi
    done
  fi
} | tee "${OUT_DIR}/${STAGE}.txt"
