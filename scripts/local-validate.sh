#!/usr/bin/env bash
# Local validation that does not require a full Firefox compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== syntax check =="
for s in scripts/*.sh; do
  bash -n "$s"
  echo "OK $s"
done

echo "== pins =="
# shellcheck source=load-pins.sh
source scripts/load-pins.sh

echo "== baseline config =="
scripts/verify-baseline-config.sh

echo "== forbid optimization env =="
if LTO=1 scripts/verify-baseline-config.sh 2>/dev/null; then
  echo "ERROR: verify-baseline-config should reject LTO=1" >&2
  exit 1
fi
echo "OK rejects LTO=1"

echo "== fetch bsys6 pin =="
scripts/fetch-bsys6.sh "${ROOT}/work/bsys6"
test "$(git -C work/bsys6 rev-parse HEAD)" = "${LWPB_BSYS6_REV}"

echo "== fetch source tarball + sha256 =="
if [[ -f "work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz" ]]; then
  echo "Source tarball already present; verifying checksum"
fi
scripts/fetch-source.sh "${ROOT}/work"
test -f "work/librewolf-${LWPB_FULL_VERSION}.source.tar.gz"

echo "== metadata writer smoke =="
mkdir -p artifacts
scripts/write-build-metadata.sh artifacts/local-validate-metadata.json ok 0 ""
jq -e '.optimizations.lto == false and .optimizations.pgo == false' artifacts/local-validate-metadata.json >/dev/null

echo "== disk report smoke =="
export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
scripts/disk-report.sh local-validate

echo
echo "Local validation PASSED (full Windows compile not run)."
echo "Next: GitHub Actions workflow baseline-windows.yml"
