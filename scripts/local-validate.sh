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
# Isolate from any leftover Phase 3/4 proof artifacts
rm -f artifacts/v3-proof.json artifacts/thinlto-proof.json
scripts/write-build-metadata.sh artifacts/local-validate-metadata.json ok 0 ""
jq -e '
  .optimizations.overlay_lto == false
  and .optimizations.overlay_lto_mode == false
  and .optimizations.overlay_pgo == false
  and .optimizations.overlay_optimizations == false
  and .optimizations.x86_64_v3 == false
  and .optimizations.csir == false
  and .optimizations.upstream_cpp_lto_mode == false
  and (.optimizations | has("upstream_rust_lto"))
  and (.optimizations | has("upstream_pgo"))
  and (.optimizations | has("upstream_cpp_lto"))
' artifacts/local-validate-metadata.json >/dev/null

echo "== memory-report smoke =="
MEMORY_REPORT_DIR="${ROOT}/artifacts/disk" scripts/memory-report.sh sample >/dev/null
MEMORY_REPORT_DIR="${ROOT}/artifacts/disk" scripts/memory-report.sh summary >/dev/null
test -f artifacts/memory-summary.json
jq -e 'has("memory_limit_bytes") and has("oom_kill_count")' artifacts/memory-summary.json >/dev/null
echo "OK memory-summary.json"

echo "== detect-optimization-state smoke =="
# Synthetic mozconfig: upstream PGO on, C++ LTO off
TMPM="$(mktemp)"
cat >"$TMPM" <<'EOF'
ac_add_options --enable-profile-use
ac_add_options --with-pgo-profile-path=/tmp/windows.profdata
EOF
scripts/detect-optimization-state.sh "$TMPM" /dev/null \
  | jq -e '.upstream_pgo == true and .upstream_cpp_lto == false and .overlay_lto == false'
rm -f "$TMPM"
echo "OK detect-optimization-state"
echo "== windows target guard =="
TARGET=windows ARCH=x86_64 scripts/verify-windows-target.sh
# Negative test: temporarily point at a fake mingw emitter if we had one — instead
# assert the pin string is not mingw32.
grep -q 'pc-windows-msvc' work/bsys6/src/exports/target.sh
if grep -n 'pc-mingw32' work/bsys6/src/exports/target.sh; then
  echo "ERROR: pinned bsys6 still contains pc-mingw32" >&2
  exit 1
fi
echo "OK pinned bsys6 uses windows-msvc"

echo "== disk report smoke =="
export DISK_REPORT_DIR="${ROOT}/artifacts/disk"
scripts/disk-report.sh local-validate

echo
echo "Local validation PASSED (full Windows compile not run)."
echo "Next: GitHub Actions workflow baseline-windows.yml"



