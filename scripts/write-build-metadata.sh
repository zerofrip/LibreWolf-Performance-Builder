#!/usr/bin/env bash
# Write machine-readable build metadata after a baseline attempt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

OUT="${1:?usage: write-build-metadata.sh <outfile.json>}"
STATUS="${2:?status required}"
DURATION_SEC="${3:-}"
ARTIFACT="${4:-}"

mkdir -p "$(dirname "$OUT")"

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
RUNNER="${RUNNER_NAME:-${RUNNER_OS:-local}}"

ARTIFACT_SHA=""
ARTIFACT_SIZE=""
if [[ -n "$ARTIFACT" && -f "$ARTIFACT" ]]; then
  ARTIFACT_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  ARTIFACT_SIZE="$(stat -c%s "$ARTIFACT" 2>/dev/null || wc -c <"$ARTIFACT")"
fi

LLVM_VER=""
RUST_VER=""
if command -v clang >/dev/null 2>&1; then
  LLVM_VER="$(clang --version 2>/dev/null | head -1 || true)"
fi
if command -v rustc >/dev/null 2>&1; then
  RUST_VER="$(rustc --version 2>/dev/null || true)"
fi

# Prefer toolchain from ~/.mozbuild if present
if [[ -x "${HOME}/.mozbuild/clang/bin/clang" ]]; then
  LLVM_VER="$("${HOME}/.mozbuild/clang/bin/clang" --version 2>/dev/null | head -1 || true)"
fi

jq -n \
  --arg status "$STATUS" \
  --arg phase "2-baseline" \
  --arg target "windows" \
  --arg arch "x86_64" \
  --arg moz_target "x86_64-pc-mingw32" \
  --arg librewolf_version "$LWPB_FULL_VERSION" \
  --arg firefox_version "$LWPB_FIREFOX_VERSION" \
  --arg bsys6_rev "$LWPB_BSYS6_REV" \
  --arg source_rev "$LWPB_SOURCE_REV" \
  --arg source_url "$LWPB_SOURCE_URL" \
  --arg source_sha256 "$LWPB_SOURCE_SHA256" \
  --arg host_os "$HOST_OS" \
  --arg host_arch "$HOST_ARCH" \
  --arg runner "$RUNNER" \
  --arg llvm "$LLVM_VER" \
  --arg rust "$RUST_VER" \
  --arg duration_sec "$DURATION_SEC" \
  --arg artifact "${ARTIFACT}" \
  --arg artifact_sha256 "$ARTIFACT_SHA" \
  --arg artifact_size "$ARTIFACT_SIZE" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson optimizations '{"lto":false,"pgo":false,"x86_64_v3":false,"csir":false}' \
  '{
    status: $status,
    phase: $phase,
    target: $target,
    arch: $arch,
    moz_target: $moz_target,
    librewolf_version: $librewolf_version,
    firefox_version: $firefox_version,
    bsys6_rev: $bsys6_rev,
    source_rev: $source_rev,
    source_url: $source_url,
    source_sha256: $source_sha256,
    host_os: $host_os,
    host_arch: $host_arch,
    runner: $runner,
    llvm_version: $llvm,
    rust_version: $rust,
    duration_sec: $duration_sec,
    artifact: $artifact,
    artifact_sha256: $artifact_sha256,
    artifact_bytes: $artifact_size,
    optimizations: $optimizations,
    timestamp_utc: $ts
  }' >"$OUT"

echo "Wrote metadata $OUT"
cat "$OUT"
