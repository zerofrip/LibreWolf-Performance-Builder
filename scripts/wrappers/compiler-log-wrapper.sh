#!/usr/bin/env bash
# Log compiler argv then exec real tool. Used only for Phase 3 evidence capture.
set -euo pipefail

LOG="${LWPB_COMPILER_LOG:-/tmp/lwpb-compiler-invocations.log}"
TOOL_KIND="${LWPB_WRAPPER_KIND:-unknown}"
REAL="${LWPB_REAL_COMPILER:?LWPB_REAL_COMPILER must be set}"

mkdir -p "$(dirname "$LOG")"
# One line JSON-ish: kind + full argv
{
  printf '%s' "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"${TOOL_KIND}\",\"argv\":["
  first=1
  for a in "$REAL" "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    # Escape for minimal JSON string
    esc="${a//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '"%s"' "$esc"
  done
  printf ']}\n'
} >>"$LOG"

exec "$REAL" "$@"
