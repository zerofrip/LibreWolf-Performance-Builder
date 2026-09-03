#!/usr/bin/env bash
# Load and verify pinned upstream metadata. Fail loudly — no silent fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${ROOT}/upstream/metadata.json"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$META" ]] || die "missing $META"
command -v jq >/dev/null 2>&1 || die "jq is required"

BSYS6_REV="$(tr -d '[:space:]' <"${ROOT}/upstream/bsys6.rev")"
SOURCE_REV="$(tr -d '[:space:]' <"${ROOT}/upstream/source.rev")"
VERSION="$(tr -d '[:space:]' <"${ROOT}/upstream/source.version")"
RELEASE="$(tr -d '[:space:]' <"${ROOT}/upstream/source.release")"
FULL_VERSION="${VERSION}-${RELEASE}"

META_VERSION="$(jq -r .librewolf_version "$META")"
META_BSYS6="$(jq -r .bsys6_rev "$META")"
META_SOURCE="$(jq -r .source_rev "$META")"
SOURCE_URL="$(jq -r .source_tarball_url "$META")"
SOURCE_SHA256="$(jq -r .source_tarball_sha256 "$META")"
FORGE_URL="$(jq -r .forge_url_for_packages "$META")"

[[ "$META_VERSION" == "$FULL_VERSION" ]] || die "metadata librewolf_version ($META_VERSION) != ${FULL_VERSION}"
[[ "$META_BSYS6" == "$BSYS6_REV" ]] || die "metadata bsys6_rev mismatch"
[[ "$META_SOURCE" == "$SOURCE_REV" ]] || die "metadata source_rev mismatch"
[[ "$SOURCE_URL" == https://* ]] || die "SOURCE_URL must be https"
[[ "$SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid source sha256"
[[ "$FORGE_URL" == "https://librewolf.dev" ]] || die "unexpected FORGE_URL pin: $FORGE_URL"

# Export for callers
export LWPB_ROOT="$ROOT"
export LWPB_BSYS6_REV="$BSYS6_REV"
export LWPB_SOURCE_REV="$SOURCE_REV"
export LWPB_VERSION="$VERSION"
export LWPB_RELEASE="$RELEASE"
export LWPB_FULL_VERSION="$FULL_VERSION"
export LWPB_SOURCE_URL="$SOURCE_URL"
export LWPB_SOURCE_SHA256="$SOURCE_SHA256"
export LWPB_FORGE_URL="$FORGE_URL"
export LWPB_BSYS6_GIT
LWPB_BSYS6_GIT="$(jq -r .bsys6_git "$META")"
export LWPB_FIREFOX_VERSION
LWPB_FIREFOX_VERSION="$(jq -r .firefox_version "$META")"

echo "Pins OK: LibreWolf ${LWPB_FULL_VERSION} (Firefox ${LWPB_FIREFOX_VERSION})"
echo "  bsys6 ${LWPB_BSYS6_REV}"
echo "  source ${LWPB_SOURCE_REV}"
echo "  tarball ${LWPB_SOURCE_URL}"
