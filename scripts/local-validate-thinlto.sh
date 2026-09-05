#!/usr/bin/env bash
# Lightweight Phase 4 validation (no full Firefox compile).
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

echo "== phase 3 v3 config still intact =="
scripts/verify-v3-config.sh

echo "== phase 4 thinlto config =="
scripts/verify-thinlto-config.sh

echo "== privacy invariants =="
scripts/check-privacy-invariants.sh

echo "== LTO=true must be rejected by thinlto verify =="
if LTO=1 scripts/verify-thinlto-config.sh 2>/dev/null; then
  echo "ERROR: verify-thinlto-config should reject LTO=1" >&2
  exit 1
fi
echo "OK rejects LTO=1"

echo "== prove-thinlto synthetic FAIL (missing evidence) =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/mozconfig" <<'EOF'
ac_add_options --target=x86_64-pc-windows-msvc
ac_add_options --enable-profile-use
ac_add_options --enable-lto=thin
# LWPB_PHASE4_THINLTO
export CFLAGS="-march=x86-64-v3"
export CXXFLAGS="-march=x86-64-v3"
export RUSTFLAGS="-C target-cpu=x86-64-v3"
EOF
if scripts/prove-thinlto.sh "$TMP/mozconfig" /dev/null /dev/null "$TMP/fail-thin.json"; then
  echo "ERROR: prove-thinlto should fail without autoconf/invocations" >&2
  exit 1
fi
echo "OK prove-thinlto fails closed"

echo "== prove-thinlto synthetic PASS =="
FAKE_WORK="$TMP/work"
mkdir -p "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config"
cp "$TMP/mozconfig" "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig"
cat >"$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config/autoconf.mk" <<'EOF'
MOZ_LTO = 1
MOZ_LTO_CFLAGS = -flto=thin
MOZ_LTO_LDFLAGS = -flto=thin -fuse-ld=lld
MOZ_LTO_RUST_CROSS =
OS_CFLAGS = -O2 -march=x86-64-v3 -flto=thin
OS_CXXFLAGS = -O2 -march=x86-64-v3 -flto=thin
HOST_CFLAGS = -O2
HOST_CXXFLAGS = -O2
RUSTFLAGS = -C target-cpu=x86-64-v3
EOF

cat >"$TMP/inv.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","kind":"clang-cl","argv":["clang-cl","-march=x86-64-v3","-flto=thin","-c","a.c"]}
{"ts":"2026-01-01T00:00:01Z","kind":"clang-cl","argv":["clang-cl","-TP","-march=x86-64-v3","-flto=thin","-c","a.cpp"]}
{"ts":"2026-01-01T00:00:02Z","kind":"rustc","argv":["rustc","--target","x86_64-pc-windows-msvc","-C","target-cpu=x86-64-v3","lib.rs"]}
EOF

cat >"$TMP/build.log" <<'EOF'
Adding configure options from /tmp/mozconfig
  --enable-lto=thin
  --enable-profile-use
Compiling gkrust v0.1.0
Finished `release` profile [optimized] target(s) in 1.0s
EOF

WORKDIR="$FAKE_WORK" scripts/prove-thinlto.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  "$TMP/build.log" \
  "$TMP/inv.jsonl" \
  "$TMP/pass-thin.json"
jq -e '.proven.thinlto == true and .effective_cpp_lto == "thin" and .full_lto == false' \
  "$TMP/pass-thin.json" >/dev/null
echo "OK prove-thinlto synthetic PASS"

echo "== prove-thinlto rejects full LTO request =="
cat >"$TMP/moz-full" <<'EOF'
ac_add_options --enable-lto=full
EOF
if scripts/prove-thinlto.sh "$TMP/moz-full" /dev/null /dev/null "$TMP/full.json"; then
  echo "ERROR: prove-thinlto should fail for full LTO" >&2
  exit 1
fi
echo "OK prove-thinlto rejects full"

echo "== detect-optimization-state Phase 4 modes =="
# Also need v3 proof for x86_64_v3 true
cat >"$TMP/v3.json" <<'EOF'
{
  "x86_64_v3": true,
  "requested": {"x86_64_v3": true},
  "proven": {
    "c_x86_64_v3": true,
    "cpp_x86_64_v3": true,
    "rust_x86_64_v3": true,
    "host_target_separation": true
  }
}
EOF
scripts/detect-optimization-state.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  "$TMP/build.log" \
  "$TMP/v3.json" \
  "$TMP/pass-thin.json" \
  | jq -e '
    .overlay_lto == true
    and .overlay_lto_mode == "thin"
    and .overlay_pgo == false
    and .upstream_cpp_lto == true
    and .upstream_cpp_lto_mode == "thin"
    and .upstream_pgo == true
    and .upstream_rust_lto == true
    and .x86_64_v3 == true
    and .csir == false
    and .proven.thinlto == true
  '
echo "OK detect Phase 4 semantics"

echo "== detect without thin proof records UNKNOWN mode =="
scripts/detect-optimization-state.sh \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  /dev/null \
  /nonexistent-v3.json \
  /nonexistent-thin.json \
  | jq -e '
    .overlay_lto == true
    and .overlay_lto_mode == "thin"
    and .upstream_cpp_lto == true
    and .upstream_cpp_lto_mode == "UNKNOWN"
    and .x86_64_v3 == false
  '
echo "OK UNKNOWN when unproven"

echo "== metadata writer smoke (phase 4) =="
mkdir -p artifacts
# Isolate: do not pick up synthetic proofs from TMP via default paths
cp "$TMP/pass-thin.json" artifacts/thinlto-proof.json
cp "$TMP/v3.json" artifacts/v3-proof.json
LWPB_BUILD_PHASE=4-x86-64-v3-thinlto \
  scripts/write-build-metadata.sh artifacts/local-validate-thinlto-metadata.json ok 0 "" \
  "$FAKE_WORK/librewolf-${LWPB_FULL_VERSION}/mozconfig" \
  "$TMP/build.log"
jq -e '
  .phase == "4-x86-64-v3-thinlto"
  and .optimizations.overlay_lto == true
  and .optimizations.overlay_lto_mode == "thin"
  and .optimizations.upstream_cpp_lto_mode == "thin"
  and .optimizations.csir == false
' artifacts/local-validate-thinlto-metadata.json >/dev/null
echo "OK metadata Phase 4"

echo "== optional container ThinLTO + v3 probes =="
if command -v docker >/dev/null 2>&1 && docker image inspect codeberg.org/librewolf/bsys6:windows >/dev/null 2>&1; then
  sg docker -c "docker run --rm --user root -v \"$ROOT:/src:ro\" -w /src codeberg.org/librewolf/bsys6:windows bash -lc '
    mkdir -p /tmp/probes
    bash scripts/probe-clang-v3.sh /tmp/probes
    bash scripts/probe-rust-v3.sh /tmp/probes
    bash scripts/probe-thinlto.sh /tmp/probes
    jq -e .thinlto_supported==true /tmp/probes/thinlto-probe.json
  '" || docker run --rm --user root -v "$ROOT:/src:ro" -w /src codeberg.org/librewolf/bsys6:windows bash -lc '
    mkdir -p /tmp/probes
    bash scripts/probe-clang-v3.sh /tmp/probes
    bash scripts/probe-rust-v3.sh /tmp/probes
    bash scripts/probe-thinlto.sh /tmp/probes
    jq -e .thinlto_supported==true /tmp/probes/thinlto-probe.json
  '
  echo "OK container clang/rust/thinlto probes"
else
  echo "SKIP container probes (docker image not available on this host)"
fi

echo
echo "Phase 4 local validation PASSED (full Windows compile not run)."
