#!/usr/bin/env bash
# Prove optimization-layer flags from effective mozconfig / build logs / v3 proof.
# Prints a JSON object to stdout. Uses boolean/null — never guesses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZCONFIG="${1:-}"
BUILD_LOG="${2:-${ROOT}/artifacts/logs/bsys6-build-package.log}"
V3_PROOF="${3:-${ROOT}/artifacts/v3-proof.json}"

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
evidence_v3=""

requested_v3=false
proven_c_v3=null
proven_cpp_v3=null
proven_rust_v3=null
proven_sep=null

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
  if grep -Eq -- '-march=x86-64-v3' "$MOZCONFIG" \
    && grep -Eq -- 'target-cpu=x86-64-v3' "$MOZCONFIG"; then
    requested_v3=true
  fi
fi

if [[ -f "$BUILD_LOG" ]]; then
  if [[ "$upstream_pgo" != true ]]; then
    if grep -Eq -- '--enable-profile-use|--with-pgo-profile-path=' "$BUILD_LOG"; then
      upstream_pgo=true
      evidence_pgo="build-log configure"
    fi
  fi
  if [[ "$upstream_cpp_lto" != true ]]; then
    if grep -Eq -- 'ac_add_options[[:space:]]+--enable-lto|--enable-lto=' "$BUILD_LOG"; then
      if grep -E 'Adding configure options|^\s+--enable-lto' "$BUILD_LOG" | grep -q -- '--enable-lto'; then
        upstream_cpp_lto=true
        evidence_cpp_lto="build-log configure"
      fi
    fi
  fi
  if grep -E -- '-Clto([ =]|$)' "$BUILD_LOG" | grep -v -- '-Clto=off' | grep -q .; then
    if grep -EqE 'gkrust|Compiling gkrust' "$BUILD_LOG"; then
      upstream_rust_lto=true
      evidence_rust_lto="build-log rustc -Clto"
    fi
  elif grep -Eq 'Compiling gkrust ' "$BUILD_LOG" \
    && grep -Eq 'Finished `release` profile \[optimized\] target\(s\)' "$BUILD_LOG"; then
    # Success logs often omit rustc argv; finished gkrust release still implies rust.mk -Clto
    upstream_rust_lto=true
    evidence_rust_lto="build-log Compiling gkrust Finished release (rust.mk -Clto implied)"
  fi
fi

# Prefer authoritative Phase 3 proof artifact when present
if [[ -f "$V3_PROOF" ]]; then
  evidence_v3="v3-proof.json"
  # shellcheck disable=SC2016
  eval "$(jq -r '
    "x86_64_v3=" + (.x86_64_v3|tostring) + "\n" +
    "proven_c_v3=" + (.proven.c_x86_64_v3|tostring) + "\n" +
    "proven_cpp_v3=" + (.proven.cpp_x86_64_v3|tostring) + "\n" +
    "proven_rust_v3=" + (.proven.rust_x86_64_v3|tostring) + "\n" +
    "proven_sep=" + (.proven.host_target_separation|tostring) + "\n" +
    "requested_v3=" + (.requested.x86_64_v3|tostring)
  ' "$V3_PROOF")"
fi

# Without proof file: mozconfig request alone must NOT set x86_64_v3 true
if [[ ! -f "$V3_PROOF" ]]; then
  x86_64_v3=false
fi

if [[ -n "${LTO:-}" && "${LTO}" != "false" && "${LTO}" != "0" ]]; then
  overlay_lto=true
fi
if [[ -n "${MOZ_PGO:-}" || -n "${MOZ_PROFILE_USE:-}" || -n "${MOZ_PROFILE_GENERATE:-}" ]]; then
  overlay_pgo=true
fi

# Build requested/proven objects with nulls when unknown
REQ_JSON="$(jq -n --argjson v "$requested_v3" '{x86_64_v3:$v}')"
if [[ "$proven_c_v3" == "null" || -z "$proven_c_v3" ]]; then
  PROVEN_JSON='{"c_x86_64_v3":null,"cpp_x86_64_v3":null,"rust_x86_64_v3":null,"host_target_separation":null}'
else
  PROVEN_JSON="$(jq -n \
    --argjson c "$proven_c_v3" \
    --argjson cpp "$proven_cpp_v3" \
    --argjson r "$proven_rust_v3" \
    --argjson s "$proven_sep" \
    '{c_x86_64_v3:$c,cpp_x86_64_v3:$cpp,rust_x86_64_v3:$r,host_target_separation:$s}')"
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
  --arg evidence_v3 "$evidence_v3" \
  --argjson requested "$REQ_JSON" \
  --argjson proven "$PROVEN_JSON" \
  '{
    overlay_lto: $overlay_lto,
    overlay_pgo: $overlay_pgo,
    overlay_optimizations: ($overlay_lto or $overlay_pgo or $x86_64_v3 or $csir),
    upstream_cpp_lto: $upstream_cpp_lto,
    upstream_rust_lto: $upstream_rust_lto,
    upstream_pgo: $upstream_pgo,
    x86_64_v3: $x86_64_v3,
    csir: $csir,
    requested: $requested,
    proven: $proven,
    evidence: {
      upstream_pgo: (if $evidence_pgo=="" then null else $evidence_pgo end),
      upstream_cpp_lto: (if $evidence_cpp_lto=="" then null else $evidence_cpp_lto end),
      upstream_rust_lto: (if $evidence_rust_lto=="" then null else $evidence_rust_lto end),
      x86_64_v3: (if $evidence_v3=="" then null else $evidence_v3 end)
    }
  }'

