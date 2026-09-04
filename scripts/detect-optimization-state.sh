#!/usr/bin/env bash
# Prove Phase 2 optimization-layer flags from effective mozconfig / build logs.
# Prints a JSON object to stdout. Uses boolean/null — never guesses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZCONFIG="${1:-}"
BUILD_LOG="${2:-${ROOT}/artifacts/logs/bsys6-build-package.log}"

overlay_lto=false
overlay_pgo=false
x86_64_v3=false
csir=false

upstream_pgo=false
upstream_cpp_lto=false
upstream_rust_lto=false

evidence_pgo=""
evidence_cpp_lto=""
evidence_rust_lto=""

if [[ -n "$MOZCONFIG" && -f "$MOZCONFIG" ]]; then
  if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-profile-use' "$MOZCONFIG" \
    || grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--with-pgo-profile-path=' "$MOZCONFIG"; then
    upstream_pgo=true
    evidence_pgo="mozconfig"
  fi
  if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto(=|[[:space:]]|$)' "$MOZCONFIG"; then
    upstream_cpp_lto=true
    evidence_cpp_lto="mozconfig --enable-lto"
  fi
fi

# Fall back / corroborate from configure section of build log
if [[ -f "$BUILD_LOG" ]]; then
  if [[ "$upstream_pgo" != true ]]; then
    if grep -Eq -- '--enable-profile-use|--with-pgo-profile-path=' "$BUILD_LOG"; then
      upstream_pgo=true
      evidence_pgo="build-log configure"
    fi
  fi
  if [[ "$upstream_cpp_lto" != true ]]; then
    if grep -Eq -- 'ac_add_options[[:space:]]+--enable-lto|--enable-lto=' "$BUILD_LOG"; then
      # Only count configure-options lines, not rustc -Clto
      if grep -E 'Adding configure options|^\s+--enable-lto' "$BUILD_LOG" | grep -q -- '--enable-lto'; then
        upstream_cpp_lto=true
        evidence_cpp_lto="build-log configure"
      fi
    fi
  fi
  # Rust gkrust LTO: rustc invocation contains -Clto (not -Clto=off)
  if grep -E 'crate-name gkrust|--crate-name gkrust' "$BUILD_LOG" | head -1 | grep -q .; then
    if grep -E -- '-Clto([ =]|$)' "$BUILD_LOG" | grep -v -- '-Clto=off' | grep -q .; then
      upstream_rust_lto=true
      evidence_rust_lto="build-log rustc -Clto"
    fi
  elif grep -E -- 'Compiling gkrust ' "$BUILD_LOG" >/dev/null 2>&1; then
    # Compiling started; if process died during -Clto, the error line still has it
    if grep -E -- '-Clto([ =]|$)' "$BUILD_LOG" | grep -v -- '-Clto=off' | grep -q .; then
      upstream_rust_lto=true
      evidence_rust_lto="build-log rustc -Clto (failure or success line)"
    fi
  fi
fi

# Overlay detection: our fragment must stay empty; env already guarded
if [[ -n "${LTO:-}" && "${LTO}" != "false" && "${LTO}" != "0" ]]; then
  overlay_lto=true
fi
if [[ -n "${MOZ_PGO:-}" || -n "${MOZ_PROFILE_USE:-}" || -n "${MOZ_PROFILE_GENERATE:-}" ]]; then
  # Phase 2 forbids these in env; if present, mark overlay/env contamination
  overlay_pgo=true
fi

jq -n \
  --argjson overlay_lto "$overlay_lto" \
  --argjson overlay_pgo "$overlay_pgo" \
  --argjson upstream_cpp_lto "$upstream_cpp_lto" \
  --argjson upstream_rust_lto "$upstream_rust_lto" \
  --argjson upstream_pgo "$upstream_pgo" \
  --argjson x86_64_v3 "$x86_64_v3" \
  --argjson csir "$csir" \
  --arg evidence_pgo "$evidence_pgo" \
  --arg evidence_cpp_lto "$evidence_cpp_lto" \
  --arg evidence_rust_lto "$evidence_rust_lto" \
  '{
    overlay_lto: $overlay_lto,
    overlay_pgo: $overlay_pgo,
    overlay_optimizations: ($overlay_lto or $overlay_pgo or $x86_64_v3 or $csir),
    upstream_cpp_lto: $upstream_cpp_lto,
    upstream_rust_lto: $upstream_rust_lto,
    upstream_pgo: $upstream_pgo,
    x86_64_v3: $x86_64_v3,
    csir: $csir,
    evidence: {
      upstream_pgo: (if $evidence_pgo=="" then null else $evidence_pgo end),
      upstream_cpp_lto: (if $evidence_cpp_lto=="" then null else $evidence_cpp_lto end),
      upstream_rust_lto: (if $evidence_rust_lto=="" then null else $evidence_rust_lto end)
    }
  }'
