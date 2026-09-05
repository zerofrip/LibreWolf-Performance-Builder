#!/usr/bin/env bash
# Stage D Windows smoke: start LibreWolf, load local page, quit.
# Usage: smoke-windows.sh <package.zip>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

PKG="${1:?package.zip}"
require_file "$PKG"
require_windows_interop

SMOKE_WIN="${WIN_TRAIN_ROOT}/smoke-${RUN_ID}"
rm -rf "$SMOKE_WIN"
mkdir -p "$SMOKE_WIN/app" "$SMOKE_WIN/profile" "$SMOKE_WIN/workload"
unzip -qo "$PKG" -d "$SMOKE_WIN/app"
require_file "$SMOKE_WIN/app/librewolf/librewolf.exe"
cp -a "${ROOT}/workloads/csir-train/." "$SMOKE_WIN/workload/"

WL_URL="file:///$(echo "$(wslpath -w "$SMOKE_WIN/workload/index.html")" | sed 's|\\|/|g')"
EXE_WIN_DIR="$(wslpath -w "$SMOKE_WIN/app/librewolf")"
PROF_WIN="$(wslpath -w "$SMOKE_WIN/profile")"

set +e
/mnt/c/Windows/System32/cmd.exe /c \
  "cd /d ${EXE_WIN_DIR} && set MOZ_HEADLESS=1&& set MOZ_DISABLE_CONTENT_SANDBOX=1&& librewolf.exe --headless --profile ${PROF_WIN} \"${WL_URL}\""
RC=$?
set -e

WIN_VER="$(/mnt/c/Windows/System32/cmd.exe /c ver 2>/dev/null | tr -d '\r' | tail -1 || true)"
write_stage_meta "${META_DIR}/stage-d-smoke.json" \
  --argjson exit "$RC" \
  --arg windows "$WIN_VER" \
  --arg package_sha "$(json_sha256 "$PKG")" \
  '{stage:"D-smoke",exit:$exit,windows:$windows,package_sha256:$package_sha}'

[[ "$RC" -eq 0 ]] || { echo "ERROR: smoke exit=$RC" >&2; exit 1; }
echo "Stage D Windows smoke PASS (exit=0)"
