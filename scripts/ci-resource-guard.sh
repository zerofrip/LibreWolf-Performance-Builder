#!/usr/bin/env bash
# CI resource guard for Firefox/LibreWolf builds.
# Goal: reduce OOM / runner-loss risk — not an optimization overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ROOT}/artifacts"
mkdir -p "${ART}/disk" "${ART}/logs"

# Cap make parallelism on constrained runners (default 2).
export MOZ_MAKE_FLAGS="${MOZ_MAKE_FLAGS:--j2}"
echo "-> MOZ_MAKE_FLAGS=${MOZ_MAKE_FLAGS}"

# Best-effort swap (often blocked in unprivileged containers).
if [[ "${LWPB_TRY_SWAP:-1}" == "1" ]]; then
  if [[ ! -e /swapfile-lwpb ]] && command -v fallocate >/dev/null 2>&1; then
    echo "-> Attempting 8G swapfile (best-effort)"
    if fallocate -l 8G /swapfile-lwpb 2>/dev/null \
      && chmod 600 /swapfile-lwpb \
      && mkswap /swapfile-lwpb >/dev/null 2>&1 \
      && swapon /swapfile-lwpb 2>/dev/null; then
      echo "-> Swap enabled"
      swapon --show | tee "${ART}/disk/swap.txt" || true
    else
      echo "-> Swap unavailable (continuing without it)"
      rm -f /swapfile-lwpb || true
    fi
  fi
fi

# Baseline memory snapshot (MemTotal / cgroup limits / events).
bash "${ROOT}/scripts/memory-report.sh" full memory-before || true

# Periodic concise heartbeat (JSONL/TSV + one-liner). Not a full dump.
heartbeat() {
  local n=0
  while true; do
    n=$((n + 1))
    {
      echo "=== heartbeat n=${n} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      bash "${ROOT}/scripts/memory-report.sh" sample || true
      df -h / /__w 2>/dev/null || df -h . 2>/dev/null || true
      if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
        du -sh "${WORKDIR}" 2>/dev/null || true
      fi
    } | tee -a "${ART}/disk/heartbeat.txt"
    sleep 60
  done
}

heartbeat &
echo $! >"${ART}/disk/heartbeat.pid"
echo "-> Heartbeat PID $(cat "${ART}/disk/heartbeat.pid")"
