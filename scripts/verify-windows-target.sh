#!/usr/bin/env bash
# Reject obsolete Windows triples that Firefox 155+ no longer accepts.
# Reports the actual MOZ_TARGET; does not silently rewrite unexpected values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

EXPECTED_WIN_X64="$(jq -r .bsys6_windows_target_x86_64 "${ROOT}/upstream/metadata.json")"
[[ "$EXPECTED_WIN_X64" == "x86_64-pc-windows-msvc" ]] \
  || die "metadata pin for Windows x64 target must be x86_64-pc-windows-msvc (got ${EXPECTED_WIN_X64})"

BSYS6_DIR="${LWPB_BSYS6_DIR:-${ROOT}/work/bsys6}"
TARGET_SH="${BSYS6_DIR}/src/exports/target.sh"
[[ -f "$TARGET_SH" ]] || die "missing $TARGET_SH (fetch bsys6 first)"

# Evaluate target.sh the same way bsys6 does
TARGET="${TARGET:-windows}"
ARCH="${ARCH:-x86_64}"
# shellcheck disable=SC1090
source "$TARGET_SH"

echo "Generated MOZ_TARGET=${MOZ_TARGET}"

case "$MOZ_TARGET" in
  *-pc-mingw32|*-pc-mingw64)
    die "obsolete Windows triple '${MOZ_TARGET}' is rejected by Firefox 155+ (see build/moz.configure/init.configure check_mingw_triplet). Expected ${EXPECTED_WIN_X64} from bsys6 >= 0ed119d / tag 155.0-1."
    ;;
esac

FF_MAJOR="${LWPB_FIREFOX_VERSION%%.*}"
if [[ "$FF_MAJOR" -ge 155 && "$TARGET" == "windows" && "$ARCH" == "x86_64" ]]; then
  if [[ "$MOZ_TARGET" != "$EXPECTED_WIN_X64" ]]; then
    die "Firefox ${LWPB_FIREFOX_VERSION} Windows x64 baseline requires MOZ_TARGET=${EXPECTED_WIN_X64}, got ${MOZ_TARGET} (no silent rewrite)"
  fi
fi

echo "Target compatibility OK for Firefox ${LWPB_FIREFOX_VERSION}."
