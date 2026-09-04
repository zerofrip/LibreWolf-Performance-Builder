#!/usr/bin/env bash
# Privacy/security invariant check for Phase 3 overlay.
# Overlay must not alter LibreWolf privacy prefs/policies/settings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "== privacy invariants =="

# Overlay must not ship privacy/settings trees
for forbidden in settings policies librewolf.cfg distribution; do
  if [[ -e "${ROOT}/${forbidden}" ]]; then
    die "overlay must not contain ${forbidden}/ (privacy surface)"
  fi
done

# No patches directory content (Phase 3 must not patch prefs)
if [[ -d "${ROOT}/patches" ]]; then
  if find "${ROOT}/patches" -type f ! -name '.gitkeep' | grep -q .; then
    die "patches/ is non-empty; Phase 3 authorization excludes privacy/security patches"
  fi
fi

# Phase 3 frag must not touch prefs/policies/telemetry
FRAG="${ROOT}/configs/mozconfig.x86-64-v3.frag"
[[ -f "$FRAG" ]] || die "missing $FRAG"
if grep -Eiq 'librewolf\.cfg|policies\.json|telemetry|MOZ_TELEMETRY|privacy|resistFingerprinting|ubo|ublock' "$FRAG"; then
  die "v3 frag must not reference privacy/security configuration"
fi
# Only allow CPU baseline exports
if grep -vE '^\s*(#|$)|LWPB_PHASE3|CFLAGS|CXXFLAGS|RUSTFLAGS|march=x86-64-v3|target-cpu=x86-64-v3' "$FRAG" | grep -q .; then
  die "v3 frag contains unexpected active lines (CPU baseline only)"
fi

# If source tree present, confirm settings files exist and were not modified by overlay
SRC_TAR="${ROOT}/work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz"
CFG_REL="lw/librewolf.cfg"
POL_REL="lw/policies.json"
if [[ -f "$SRC_TAR" ]]; then
  tar -tzf "$SRC_TAR" "librewolf-${LWPB_FULL_VERSION}/${CFG_REL}" >/dev/null 2>&1 \
    || die "upstream tarball missing ${CFG_REL}"
  tar -tzf "$SRC_TAR" "librewolf-${LWPB_FULL_VERSION}/${POL_REL}" >/dev/null 2>&1 \
    || die "upstream tarball missing ${POL_REL}"
  echo "OK upstream tarball contains LibreWolf cfg/policies (${CFG_REL}, ${POL_REL})"
fi

# Work tree must not have overlay-edited settings if extracted
WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
SOURCEDIR="${WORKDIR}/librewolf-${LWPB_FULL_VERSION}"
if [[ -f "$SOURCEDIR/${CFG_REL}" && -f "$SRC_TAR" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  tar -xzf "$SRC_TAR" -C "$TMP" \
    "librewolf-${LWPB_FULL_VERSION}/${CFG_REL}" \
    "librewolf-${LWPB_FULL_VERSION}/${POL_REL}"
  cmp -s "$TMP/librewolf-${LWPB_FULL_VERSION}/${CFG_REL}" \
    "$SOURCEDIR/${CFG_REL}" \
    || die "librewolf.cfg diverged from upstream tarball"
  cmp -s "$TMP/librewolf-${LWPB_FULL_VERSION}/${POL_REL}" \
    "$SOURCEDIR/${POL_REL}" \
    || die "policies.json diverged from upstream tarball"
  echo "OK extracted cfg/policies match upstream tarball"
fi

echo "PRIVACY_INVARIANTS=PASS"
