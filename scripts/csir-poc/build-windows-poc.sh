#!/usr/bin/env bash
# Build a Windows-target PE for the CSIR PoC inside the pinned bsys6 image.
# Usage: build-windows-poc.sh <output.exe> <extra_cflags...>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-poc/common.sh"

OUT="${1:?usage: build-windows-poc.sh <out.exe> [cflags...]}"
shift || true
EXTRA_CFLAGS=("$@")

require_file "$POC_SRC"
chmod +x "${ROOT}/scripts/csir-poc/docker-build-inner.sh"

if [[ "$OUT" = /* ]]; then
  REL_OUT="${OUT#"$ROOT"/}"
else
  REL_OUT="$OUT"
fi
[[ -n "$REL_OUT" ]] || REL_OUT="artifacts/csir-poc/bin/$(basename "$OUT")"

mkdir -p "$(dirname "${ROOT}/${REL_OUT}")"

docker run --rm --user root \
  -e LWPB_WINDOWS_TARGET_X64="$TARGET" \
  -v "${ROOT}:/src" \
  -w /src \
  "$IMG" \
  bash /src/scripts/csir-poc/docker-build-inner.sh "$REL_OUT" ${EXTRA_CFLAGS[@]+"${EXTRA_CFLAGS[@]}"}

# Normalize ownership for host user
docker run --rm --user root -v "${ROOT}:/src" "$IMG" \
  bash -lc "chown -R 1000:1000 /src/artifacts/csir-poc || true"

require_file "${ROOT}/${REL_OUT}"
HDR="$(dd if="${ROOT}/${REL_OUT}" bs=2 count=1 2>/dev/null || true)"
[[ "$HDR" == $'MZ' ]] || { echo "ERROR: not PE(MZ): ${ROOT}/${REL_OUT}" >&2; exit 1; }
echo "Built ${ROOT}/${REL_OUT}"
