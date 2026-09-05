#!/usr/bin/env bash
# Prove optimization-layer flags from effective mozconfig / build logs / proofs.
# Prints a JSON object to stdout. Uses boolean/null/UNKNOWN — never guesses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZCONFIG="${1:-}"
BUILD_LOG="${2:-${ROOT}/artifacts/logs/bsys6-build-package.log}"
V3_PROOF="${3:-${ROOT}/artifacts/v3-proof.json}"
THINLTO_PROOF="${4:-${ROOT}/artifacts/thinlto-proof.json}"

overlay_lto=false
overlay_lto_mode="null"
overlay_pgo=false
x86_64_v3=false
csir=false

upstream_pgo=false
upstream_cpp_lto=false
upstream_cpp_lto_mode="null"
upstream_rust_lto=false

evidence_pgo=""
evidence_cpp_lto=""
evidence_rust_lto=""
evidence_v3=""
evidence_lto=""

requested_v3=false
proven_c_v3=null
proven_cpp_v3=null
proven_rust_v3=null
proven_sep=null

requested_thin=false
thinlto_proven=false
thinlto_effective="null"

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
  if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto=thin([[:space:],]|$)' "$MOZCONFIG" \
    || grep -q 'LWPB_PHASE4_THINLTO' "$MOZCONFIG"; then
    requested_thin=true
    overlay_lto=true
    overlay_lto_mode='"thin"'
    evidence_lto="mozconfig --enable-lto=thin"
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

# Prefer ThinLTO proof for effective mode only when mozconfig requested thin.
# Do not let leftover artifacts/thinlto-proof.json contaminate Phase 2/3 metadata.
if [[ -f "$THINLTO_PROOF" && "$requested_thin" == true ]]; then
  evidence_lto="thinlto-proof.json"
  eval "$(jq -r '
    "thinlto_proven=" + ((.proven.thinlto // .thinlto // false)|tostring) + "\n" +
    (if (.effective_cpp_lto == false or .effective_cpp_lto == null) then
      "thinlto_effective=false"
     elif (.effective_cpp_lto|type) == "string" then
      "thinlto_effective=" + .effective_cpp_lto
     else
      "thinlto_effective=UNKNOWN"
     end)
  ' "$THINLTO_PROOF")"
  overlay_lto=true
  overlay_lto_mode='"thin"'
  if [[ "$thinlto_proven" == true && "$thinlto_effective" == "thin" ]]; then
    upstream_cpp_lto=true
    upstream_cpp_lto_mode='"thin"'
  else
    upstream_cpp_lto=true
    upstream_cpp_lto_mode='"UNKNOWN"'
  fi
elif [[ "$requested_thin" == true ]]; then
  # Thin requested in mozconfig but no proof artifact yet
  upstream_cpp_lto=true
  upstream_cpp_lto_mode='"UNKNOWN"'
fi

# Legacy: bsys6 LTO env still marks overlay contamination (Phase 2/4 forbid truthy LTO)
if [[ -n "${LTO:-}" && "${LTO}" != "false" && "${LTO}" != "0" ]]; then
  overlay_lto=true
  if [[ "$overlay_lto_mode" == "null" ]]; then
    overlay_lto_mode='"env"'
  fi
fi
if [[ -n "${MOZ_PGO:-}" || -n "${MOZ_PROFILE_USE:-}" || -n "${MOZ_PROFILE_GENERATE:-}" ]]; then
  overlay_pgo=true
fi

# Build requested/proven objects with nulls when unknown
REQ_JSON="$(jq -n \
  --argjson v "$requested_v3" \
  --argjson thin "$requested_thin" \
  '{x86_64_v3:$v, overlay_lto_thin:$thin}')"

PROVEN_THIN=null
if [[ -f "$THINLTO_PROOF" && "$requested_thin" == true ]]; then
  PROVEN_THIN="$thinlto_proven"
fi

if [[ "$proven_c_v3" == "null" || -z "$proven_c_v3" ]]; then
  PROVEN_JSON="$(jq -n --argjson t "${PROVEN_THIN}" \
    '{c_x86_64_v3:null,cpp_x86_64_v3:null,rust_x86_64_v3:null,host_target_separation:null,thinlto:$t}')"
else
  PROVEN_JSON="$(jq -n \
    --argjson c "$proven_c_v3" \
    --argjson cpp "$proven_cpp_v3" \
    --argjson r "$proven_rust_v3" \
    --argjson s "$proven_sep" \
    --argjson t "${PROVEN_THIN}" \
    '{c_x86_64_v3:$c,cpp_x86_64_v3:$cpp,rust_x86_64_v3:$r,host_target_separation:$s,thinlto:$t}')"
fi

# Resolve mode JSON literals (null | "thin" | "UNKNOWN" | "env" | false)
if [[ "$overlay_lto" != true ]]; then
  overlay_lto_mode="false"
fi
if [[ "$upstream_cpp_lto" != true && "$upstream_cpp_lto_mode" == "null" ]]; then
  upstream_cpp_lto_mode="false"
fi

jq -n \
  --argjson overlay_lto "$overlay_lto" \
  --argjson overlay_lto_mode "${overlay_lto_mode}" \
  --argjson overlay_pgo "$overlay_pgo" \
  --argjson upstream_cpp_lto "$upstream_cpp_lto" \
  --argjson upstream_cpp_lto_mode "${upstream_cpp_lto_mode}" \
  --argjson upstream_rust_lto "$upstream_rust_lto" \
  --argjson upstream_pgo "$upstream_pgo" \
  --argjson x86_64_v3 "$x86_64_v3" \
  --argjson csir "$csir" \
  --arg evidence_pgo "$evidence_pgo" \
  --arg evidence_cpp_lto "$evidence_cpp_lto" \
  --arg evidence_rust_lto "$evidence_rust_lto" \
  --arg evidence_v3 "$evidence_v3" \
  --arg evidence_lto "$evidence_lto" \
  --argjson requested "$REQ_JSON" \
  --argjson proven "$PROVEN_JSON" \
  '{
    overlay_lto: $overlay_lto,
    overlay_lto_mode: $overlay_lto_mode,
    overlay_pgo: $overlay_pgo,
    overlay_optimizations: ($overlay_lto or $overlay_pgo or $x86_64_v3 or $csir),
    upstream_cpp_lto: $upstream_cpp_lto,
    upstream_cpp_lto_mode: $upstream_cpp_lto_mode,
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
      x86_64_v3: (if $evidence_v3=="" then null else $evidence_v3 end),
      overlay_lto: (if $evidence_lto=="" then null else $evidence_lto end)
    }
  }'
