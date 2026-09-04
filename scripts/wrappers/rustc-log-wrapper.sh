#!/usr/bin/env bash
# RUSTC_WRAPPER entrypoint: invoked as wrapper <rustc> <args...>
set -euo pipefail

LOG="${LWPB_COMPILER_LOG:-/tmp/lwpb-compiler-invocations.log}"
REAL="${1:?rustc path required}"
shift

mkdir -p "$(dirname "$LOG")"
{
  printf '%s' "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"rustc\",\"argv\":["
  first=1
  for a in "$REAL" "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    esc="${a//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '"%s"' "$esc"
  done
  printf ']}\n'
} >>"$LOG"

exec "$REAL" "$@"
