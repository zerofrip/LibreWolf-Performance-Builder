#!/usr/bin/env bash
# Lightweight Phase 3 validation (no full Firefox compile).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== syntax check =="
for s in scripts/*.sh scripts/wrappers/*.sh; do
  [[ -f "$s" ]] || continue
  bash -n "$s"
  echo "OK $s"
done

echo "== pins =="
# shellcheck source=load-pins.sh
source scripts/load-pins.sh

echo "== baseline frag still empty =="
scripts/verify-baseline-config.sh

echo "== phase 3 v3 config =="
scripts/verify-v3-config.sh

echo "== privacy invariants =="
scripts/check-privacy-invariants.sh

echo "== prove-march-v3 synthetic FAIL (missing evidence) =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/mozconfig" <<'EOF'
ac_add_options --target=x86_64-pc-windows-msvc
ac_add_options --enable-profile-use
export CFLAGS="-march=x86-64-v3"
export CXXFLAGS="-march=x86-64-v3"
export RUSTFLAGS="-C target-cpu=x86-64-v3"
EOF
if scripts/prove-march-v3.sh "$TMP/mozconfig" /dev/null /dev/null "$TMP/fail.json"; then
  echo "ERROR: prove-march-v3 should fail without autoconf/invocations" >&2
  exit 1
fi
echo "OK prove-march-v3 fails closed"

echo "== prove-march-v3 synthetic PASS =="
mkdir -p "$TMP/obj/config"
cat >"$TMP/obj/config/autoconf.mk" <<'EOF'
OS_CFLAGS = -O2 -march=x86-64-v3
OS_CXXFLAGS = -O2 -march=x86-64-v3
HOST_CFLAGS = -O2
HOST_CXXFLAGS = -O2
RUSTFLAGS = -C target-cpu=x86-64-v3
EOF
# Point WORKDIR layout expected by prove script via fake tree
FAKE_WORK="$TMP/work"
mkdir -p "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}"
cp "$TMP/mozconfig" "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig"
# Place autoconf where prove-march-v3 looks — use explicit env by copying to expected path
mkdir -p "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config"
cp "$TMP/obj/config/autoconf.mk" \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config/autoconf.mk"

cat >"$TMP/inv.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","kind":"clang-cl","argv":["clang-cl","-march=x86-64-v3","-c","a.c"]}
{"ts":"2026-01-01T00:00:01Z","kind":"clang-cl","argv":["clang-cl","-TP","-march=x86-64-v3","-c","a.cpp"]}
{"ts":"2026-01-01T00:00:02Z","kind":"rustc","argv":["rustc","--target","x86_64-pc-windows-msvc","-C","target-cpu=x86-64-v3","lib.rs"]}
EOF

WORKDIR="$FAKE_WORK" scripts/prove-march-v3.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  /dev/null \
  "$TMP/inv.jsonl" \
  "$TMP/pass.json"
jq -e '.x86_64_v3 == true and .proven.rust_x86_64_v3 == true' "$TMP/pass.json" >/dev/null
echo "OK prove-march-v3 synthetic PASS"

echo "== detect-optimization-state with proof =="
scripts/detect-optimization-state.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  /dev/null \
  "$TMP/pass.json" \
  | jq -e '.x86_64_v3 == true and .requested.x86_64_v3 == true and .upstream_pgo == true'

echo "== detect without proof must not claim v3 =="
scripts/detect-optimization-state.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  /dev/null \
  /nonexistent-v3-proof.json \
  | jq -e '.x86_64_v3 == false and .requested.x86_64_v3 == true'

echo "== metadata writer smoke (phase 3) =="
mkdir -p artifacts
LWPB_BUILD_PHASE=3-x86-64-v3 \
  scripts/write-build-metadata.sh artifacts/local-validate-v3-metadata.json ok 0 ""
jq -e '.phase == "3-x86-64-v3"' artifacts/local-validate-v3-metadata.json >/dev/null

echo "== optional container toolchain probes =="
if command -v docker >/dev/null 2>&1 && docker image inspect codeberg.org/librewolf/bsys6:windows >/dev/null 2>&1; then
  sg docker -c "docker run --rm --user root -v \"$ROOT:/src:ro\" -w /src codeberg.org/librewolf/bsys6:windows bash -lc '
    mkdir -p /tmp/probes
    bash scripts/probe-clang-v3.sh /tmp/probes
    bash scripts/probe-rust-v3.sh /tmp/probes
  '" || docker run --rm --user root -v "$ROOT:/src:ro" -w /src codeberg.org/librewolf/bsys6:windows bash -lc '
    mkdir -p /tmp/probes
    bash scripts/probe-clang-v3.sh /tmp/probes
    bash scripts/probe-rust-v3.sh /tmp/probes
  '
  echo "OK container clang/rust v3 probes"
else
  echo "SKIP container probes (docker image not available on this host)"
fi

echo
echo "Phase 3 local validation PASSED (full Windows compile not run)."

