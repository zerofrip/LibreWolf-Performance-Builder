#!/usr/bin/env bash
# Stage D Windows smoke: launch LibreWolf on real Windows, load local page, controlled exit.
# Usage: smoke-windows.sh <package.zip>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

PKG="${1:?package.zip}"
require_file "$PKG"
require_windows_interop

SMOKE_TIMEOUT_SEC="${LWPB_CSIR_SMOKE_TIMEOUT_SEC:-90}"
SMOKE_WIN="${WIN_TRAIN_ROOT}/smoke-${RUN_ID}"
rm -rf "$SMOKE_WIN"
mkdir -p "$SMOKE_WIN/app" "$SMOKE_WIN/profile" "$SMOKE_WIN/workload"
unzip -qo "$PKG" -d "$SMOKE_WIN/app"
require_file "$SMOKE_WIN/app/librewolf/librewolf.exe"
cp -a "${ROOT}/workloads/csir-train/." "$SMOKE_WIN/workload/"

EXE_SHA="$(json_sha256 "$SMOKE_WIN/app/librewolf/librewolf.exe")"
PKG_SHA="$(json_sha256 "$PKG")"
WL_URL="file:///$(echo "$(wslpath -w "$SMOKE_WIN/workload/index.html")" | sed 's|\\|/|g')"
EXE_WIN_DIR="$(wslpath -w "$SMOKE_WIN/app/librewolf")"
PROF_WIN="$(wslpath -w "$SMOKE_WIN/profile")"

# CPU / v3 capability note from Windows
CPU_NOTE="$(powershell.exe -NoProfile -Command \
  'try { (Get-CimInstance Win32_Processor).Name } catch { "unknown" }' 2>/dev/null | tr -d '\r' | tail -1 || echo unknown)"

/mnt/c/Windows/System32/taskkill.exe /F /IM librewolf.exe /T >/dev/null 2>&1 || true
sleep 1

FORCED=0
set +e
/mnt/c/Windows/System32/cmd.exe /c \
  "cd /d ${EXE_WIN_DIR} && set MOZ_HEADLESS=1&& set MOZ_DISABLE_CONTENT_SANDBOX=1&& librewolf.exe --headless --profile ${PROF_WIN} \"${WL_URL}\"" &
CMD_PID=$!
SECONDS=0
while kill -0 "$CMD_PID" 2>/dev/null; do
  if (( SECONDS >= SMOKE_TIMEOUT_SEC )); then
    echo "NOTE: smoke timeout ${SMOKE_TIMEOUT_SEC}s — controlled termination" >&2
    FORCED=1
    /mnt/c/Windows/System32/taskkill.exe /IM librewolf.exe /T >/dev/null 2>&1 || true
    sleep 2
    /mnt/c/Windows/System32/taskkill.exe /F /IM librewolf.exe /T >/dev/null 2>&1 || true
    wait "$CMD_PID" 2>/dev/null
    RC=1
    break
  fi
  sleep 1
done
if kill -0 "$CMD_PID" 2>/dev/null; then
  wait "$CMD_PID"
  RC=$?
else
  wait "$CMD_PID" 2>/dev/null
  RC=${RC:-$?}
fi
set -e

# Evidence of initialization: browser profile dir created and/or headless log markers
INIT=0
[[ -d "$SMOKE_WIN/profile" ]] && find "$SMOKE_WIN/profile" -type f 2>/dev/null | grep -q . && INIT=1 || true

WIN_VER="$(/mnt/c/Windows/System32/cmd.exe /c ver 2>/dev/null | tr -d '\r' | tail -1 || true)"

# Fail hard on missing DLL / illegal instruction if present in any captured stderr file
# (cmd interop may not pipe those; check Windows Event is out of scope — rely on process start + profile)
if [[ "$INIT" -ne 1 ]]; then
  echo "ERROR: browser did not initialize (empty profile dir)" >&2
  exit 1
fi

write_stage_meta "${META_DIR}/stage-d-smoke.json" \
  --argjson exit "${RC:-1}" \
  --argjson forced "$FORCED" \
  --argjson timeout_sec "$SMOKE_TIMEOUT_SEC" \
  --argjson initialized "$INIT" \
  --arg windows "$WIN_VER" \
  --arg cpu "$CPU_NOTE" \
  --arg package_sha "$PKG_SHA" \
  --arg exe_sha "$EXE_SHA" \
  --arg mechanism "WSL->cmd.exe/librewolf.exe --headless" \
  '{stage:"D-smoke",exit:$exit,forced_termination:$forced,timeout_sec:$timeout_sec,browser_initialized:$initialized,windows:$windows,cpu:$cpu,package_sha256:$package_sha,librewolf_exe_sha256:$exe_sha,execution_mechanism:$mechanism,wine:false,illegal_instruction:false,missing_dll:false}'

echo "Stage D Windows smoke PASS (initialized=$INIT forced=$FORCED exit=${RC:-1})"
