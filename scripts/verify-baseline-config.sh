#!/usr/bin/env bash
# Ensure baseline config does not sneak in optimization flags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAG="${ROOT}/configs/mozconfig.baseline.frag"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$FRAG" ]] || die "missing baseline fragment $FRAG"

# Strip comments/blank lines; any remaining content is forbidden for Phase 2.
CONTENT="$(grep -vE '^\s*(#|$)' "$FRAG" || true)"
if [[ -n "${CONTENT}" ]]; then
  die "baseline fragment must be empty of active mozconfig lines; found:
${CONTENT}"
fi

# Guardrail: no optimization knobs in Phase 2 env
FORBIDDEN_ENV=(LTO MOZ_PGO MOZ_PROFILE_GENERATE MOZ_PROFILE_USE)
for v in "${FORBIDDEN_ENV[@]}"; do
  if [[ -n "${!v:-}" ]]; then
    die "Phase 2 forbids ${v}=${!v} (upstream-equivalent baseline only)"
  fi
done

echo "Baseline config OK (no optimization overlays, no LTO/PGO env)."
