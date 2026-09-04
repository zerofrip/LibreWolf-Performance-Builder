#!/usr/bin/env bash
# Best-effort memory / cgroup / OOM diagnostics for CI.
# Modes:
#   full <label>     — human-readable snapshot (before/after)
#   sample           — concise heartbeat line + JSONL append
#   summary          — write artifacts/memory-summary.json from latest cgroup state
#
# Does not change build behavior. Use null in JSON when values are unavailable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-full}"
LABEL="${2:-memory}"
OUT_DIR="${MEMORY_REPORT_DIR:-${ROOT}/artifacts/disk}"
ART_DIR="${ROOT}/artifacts"
mkdir -p "$OUT_DIR" "$ART_DIR"

JSONL="${OUT_DIR}/memory-samples.jsonl"
TSV="${OUT_DIR}/memory-samples.tsv"

# --- helpers ---

meminfo_kb() {
  local key="$1"
  if [[ -r /proc/meminfo ]]; then
    awk -v k="$key" '$1 == k ":" {print $2; exit}' /proc/meminfo
  fi
}

# Resolve cgroup v2 memory controller directory for this process.
find_cg2() {
  local cand rel
  for cand in /sys/fs/cgroup /sys/fs/cgroup/memory; do
    if [[ -e "${cand}/memory.max" || -e "${cand}/memory.current" ]]; then
      echo "$cand"
      return 0
    fi
  done
  if [[ -f /proc/self/cgroup ]]; then
    rel="$(awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup || true)"
    # Walk up from the most specific path until memory.max exists.
    while [[ -n "$rel" && "$rel" != "/" ]]; do
      if [[ -e "/sys/fs/cgroup${rel}/memory.max" || -e "/sys/fs/cgroup${rel}/memory.current" ]]; then
        echo "/sys/fs/cgroup${rel}"
        return 0
      fi
      rel="$(dirname "$rel")"
    done
    if [[ -e /sys/fs/cgroup/memory.max || -e /sys/fs/cgroup/memory.current ]]; then
      echo /sys/fs/cgroup
      return 0
    fi
  fi
  return 1
}

find_cg1() {
  local rel cand
  rel="$(awk -F: '$2=="memory"{print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  for cand in "/sys/fs/cgroup/memory${rel}" /sys/fs/cgroup/memory; do
    if [[ -e "${cand}/memory.limit_in_bytes" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

# Read a file; print empty if missing.
read_file() {
  local f="$1"
  if [[ -r "$f" ]]; then
    tr -d '\n' <"$f"
  fi
}

# Parse cgroup v2 memory.events key=value lines.
event_val() {
  local events_file="$1" key="$2"
  if [[ -r "$events_file" ]]; then
    awk -v k="$key" '$1==k {print $2; exit}' "$events_file"
  fi
}

# Convert cgroup "max" or numeric string to JSON number or null.
json_bytes() {
  local v="${1:-}"
  if [[ -z "$v" || "$v" == "max" || "$v" == "unlimited" ]]; then
    echo "null"
    return
  fi
  # cgroup v1 sometimes uses very large sentinel (~2^63-1)
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    # Treat absurd limits (> 1 PiB) as unlimited
    if (( v > 1125899906842624 )); then
      echo "null"
    else
      echo "$v"
    fi
  else
    echo "null"
  fi
}

json_int_or_null() {
  local v="${1:-}"
  if [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]]; then
    echo "null"
  else
    echo "$v"
  fi
}

collect_fields() {
  # Sets globals used by sample/summary/full
  MEM_TOTAL_KB="$(meminfo_kb MemTotal || true)"
  MEM_AVAIL_KB="$(meminfo_kb MemAvailable || true)"
  MEM_FREE_KB="$(meminfo_kb MemFree || true)"
  SWAP_TOTAL_KB="$(meminfo_kb SwapTotal || true)"
  SWAP_FREE_KB="$(meminfo_kb SwapFree || true)"

  CG2="$(find_cg2 || true)"
  CG1="$(find_cg1 || true)"

  MEMORY_CURRENT=""
  MEMORY_PEAK=""
  MEMORY_MAX=""
  SWAP_CURRENT=""
  SWAP_MAX=""
  OOM_COUNT=""
  OOM_KILL_COUNT=""
  CG_KIND=""

  if [[ -n "$CG2" ]]; then
    CG_KIND="v2"
    MEMORY_CURRENT="$(read_file "${CG2}/memory.current")"
    MEMORY_PEAK="$(read_file "${CG2}/memory.peak")"
    MEMORY_MAX="$(read_file "${CG2}/memory.max")"
    SWAP_CURRENT="$(read_file "${CG2}/memory.swap.current")"
    SWAP_MAX="$(read_file "${CG2}/memory.swap.max")"
    OOM_COUNT="$(event_val "${CG2}/memory.events" oom)"
    OOM_KILL_COUNT="$(event_val "${CG2}/memory.events" oom_kill)"
  elif [[ -n "$CG1" ]]; then
    CG_KIND="v1"
    MEMORY_CURRENT="$(read_file "${CG1}/memory.usage_in_bytes")"
    MEMORY_PEAK="$(read_file "${CG1}/memory.max_usage_in_bytes")"
    MEMORY_MAX="$(read_file "${CG1}/memory.limit_in_bytes")"
    OOM_COUNT="$(read_file "${CG1}/memory.failcnt")"
    if [[ -r "${CG1}/memory.oom_control" ]]; then
      # Prefer explicit oom_kill counter when present (newer kernels).
      OOM_KILL_COUNT="$(awk '/^oom_kill / {print $2; exit}' "${CG1}/memory.oom_control" || true)"
    fi
  fi
}

append_sample() {
  collect_fields
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Human one-liner
  echo "ts=${ts} MemTotal_kB=${MEM_TOTAL_KB:-?} MemAvailable_kB=${MEM_AVAIL_KB:-?} SwapTotal_kB=${SWAP_TOTAL_KB:-?} SwapFree_kB=${SWAP_FREE_KB:-?} cg=${CG_KIND:-none} memory.current=${MEMORY_CURRENT:-?} memory.peak=${MEMORY_PEAK:-?} memory.max=${MEMORY_MAX:-?} oom=${OOM_COUNT:-?} oom_kill=${OOM_KILL_COUNT:-?} swap.current=${SWAP_CURRENT:-?} swap.max=${SWAP_MAX:-?}"

  # TSV header once
  if [[ ! -f "$TSV" ]]; then
    echo -e "ts\tMemTotal_kB\tMemAvailable_kB\tSwapTotal_kB\tSwapFree_kB\tcg\tmemory_current\tmemory_peak\tmemory_max\toom\toom_kill\tswap_current\tswap_max" >"$TSV"
  fi
  echo -e "${ts}\t${MEM_TOTAL_KB}\t${MEM_AVAIL_KB}\t${SWAP_TOTAL_KB}\t${SWAP_FREE_KB}\t${CG_KIND}\t${MEMORY_CURRENT}\t${MEMORY_PEAK}\t${MEMORY_MAX}\t${OOM_COUNT}\t${OOM_KILL_COUNT}\t${SWAP_CURRENT}\t${SWAP_MAX}" >>"$TSV"

  # JSONL
  jq -nc \
    --arg ts "$ts" \
    --arg cg "${CG_KIND}" \
    --argjson MemTotal_kB "$(json_int_or_null "$MEM_TOTAL_KB")" \
    --argjson MemAvailable_kB "$(json_int_or_null "$MEM_AVAIL_KB")" \
    --argjson SwapTotal_kB "$(json_int_or_null "$SWAP_TOTAL_KB")" \
    --argjson SwapFree_kB "$(json_int_or_null "$SWAP_FREE_KB")" \
    --argjson memory_current "$(json_bytes "$MEMORY_CURRENT")" \
    --argjson memory_peak "$(json_bytes "$MEMORY_PEAK")" \
    --argjson memory_max "$(json_bytes "$MEMORY_MAX")" \
    --argjson oom "$(json_int_or_null "$OOM_COUNT")" \
    --argjson oom_kill "$(json_int_or_null "$OOM_KILL_COUNT")" \
    --argjson swap_current "$(json_bytes "$SWAP_CURRENT")" \
    --argjson swap_max "$(json_bytes "$SWAP_MAX")" \
    '{
      ts:$ts, cg:$cg,
      MemTotal_kB:$MemTotal_kB, MemAvailable_kB:$MemAvailable_kB,
      SwapTotal_kB:$SwapTotal_kB, SwapFree_kB:$SwapFree_kB,
      memory_current:$memory_current, memory_peak:$memory_peak, memory_max:$memory_max,
      oom:$oom, oom_kill:$oom_kill,
      swap_current:$swap_current, swap_max:$swap_max
    }' >>"$JSONL"
}

write_summary() {
  collect_fields
  local out="${ART_DIR}/memory-summary.json"
  local peak_from_samples="null"
  if [[ -f "$JSONL" ]] && command -v jq >/dev/null 2>&1; then
    peak_from_samples="$(jq -s '[.[].memory_peak | select(. != null)] | if length>0 then max else null end' "$JSONL" 2>/dev/null || echo null)"
  fi

  local mem_peak_json
  mem_peak_json="$(json_bytes "$MEMORY_PEAK")"
  if [[ "$mem_peak_json" == "null" && "$peak_from_samples" != "null" ]]; then
    mem_peak_json="$peak_from_samples"
  fi

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cg "${CG_KIND}" \
    --arg cg_path "${CG2:-${CG1:-}}" \
    --argjson MemTotal_kB "$(json_int_or_null "$MEM_TOTAL_KB")" \
    --argjson MemAvailable_kB "$(json_int_or_null "$MEM_AVAIL_KB")" \
    --argjson SwapTotal_kB "$(json_int_or_null "$SWAP_TOTAL_KB")" \
    --argjson SwapFree_kB "$(json_int_or_null "$SWAP_FREE_KB")" \
    --argjson memory_limit_bytes "$(json_bytes "$MEMORY_MAX")" \
    --argjson memory_peak_bytes "$mem_peak_json" \
    --argjson memory_current_bytes "$(json_bytes "$MEMORY_CURRENT")" \
    --argjson oom_count "$(json_int_or_null "$OOM_COUNT")" \
    --argjson oom_kill_count "$(json_int_or_null "$OOM_KILL_COUNT")" \
    --argjson swap_limit_bytes "$(json_bytes "$SWAP_MAX")" \
    --argjson swap_peak_bytes "null" \
    --argjson swap_current_bytes "$(json_bytes "$SWAP_CURRENT")" \
    '{
      timestamp_utc: $ts,
      cgroup_kind: (if $cg=="" then null else $cg end),
      cgroup_path: (if $cg_path=="" then null else $cg_path end),
      MemTotal_kB: $MemTotal_kB,
      MemAvailable_kB: $MemAvailable_kB,
      SwapTotal_kB: $SwapTotal_kB,
      SwapFree_kB: $SwapFree_kB,
      memory_limit_bytes: $memory_limit_bytes,
      memory_peak_bytes: $memory_peak_bytes,
      memory_current_bytes: $memory_current_bytes,
      oom_count: $oom_count,
      oom_kill_count: $oom_kill_count,
      swap_limit_bytes: $swap_limit_bytes,
      swap_peak_bytes: $swap_peak_bytes,
      swap_current_bytes: $swap_current_bytes,
      note: "Authoritative limit is memory_limit_bytes (cgroup) when non-null; do not assume GitHub-hosted RAM from docs alone."
    }' >"$out"

  echo "Wrote $out"
  cat "$out"
}

full_report() {
  local out="${OUT_DIR}/${LABEL}.txt"
  collect_fields
  {
    echo "=== memory-report label=${LABEL} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

    echo "--- /proc/meminfo (selected) ---"
    if [[ -r /proc/meminfo ]]; then
      grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|AnonPages|Mapped|Shmem|CommitLimit|Committed_AS):' /proc/meminfo || cat /proc/meminfo
    else
      echo "(unreadable)"
    fi

    echo "--- free -h ---"
    if command -v free >/dev/null 2>&1; then
      free -h
    else
      echo "(free not installed)"
    fi

    echo "--- ulimit -a ---"
    ulimit -a 2>&1 || true

    echo "--- cgroup detection ---"
    if [[ -f /proc/self/cgroup ]]; then
      cat /proc/self/cgroup
    else
      echo "(no /proc/self/cgroup)"
    fi

    echo "--- cgroup v2 memory ---"
    if [[ -n "${CG2:-}" ]]; then
      echo "path=${CG2}"
      for f in memory.max memory.high memory.current memory.peak memory.events memory.swap.max memory.swap.current memory.stat; do
        if [[ -r "${CG2}/${f}" ]]; then
          echo "== ${f} =="
          cat "${CG2}/${f}"
        fi
      done
    else
      echo "(no cgroup v2 memory controller path found)"
    fi

    echo "--- cgroup v1 memory ---"
    if [[ -n "${CG1:-}" ]]; then
      echo "path=${CG1}"
      for f in memory.limit_in_bytes memory.usage_in_bytes memory.max_usage_in_bytes memory.failcnt memory.oom_control; do
        if [[ -r "${CG1}/${f}" ]]; then
          echo "== ${f} =="
          cat "${CG1}/${f}"
        fi
      done
    else
      echo "(no cgroup v1 memory controller path found)"
    fi

    echo "--- concise fields ---"
    echo "MemTotal_kB=${MEM_TOTAL_KB:-}"
    echo "MemAvailable_kB=${MEM_AVAIL_KB:-}"
    echo "SwapTotal_kB=${SWAP_TOTAL_KB:-}"
    echo "SwapFree_kB=${SWAP_FREE_KB:-}"
    echo "memory.current=${MEMORY_CURRENT:-}"
    echo "memory.peak=${MEMORY_PEAK:-}"
    echo "memory.max=${MEMORY_MAX:-}"
    echo "oom=${OOM_COUNT:-}"
    echo "oom_kill=${OOM_KILL_COUNT:-}"
    echo "swap.current=${SWAP_CURRENT:-}"
    echo "swap.max=${SWAP_MAX:-}"

    echo "--- dmesg OOM (best-effort; often blocked) ---"
    if command -v dmesg >/dev/null 2>&1; then
      if dmesg -T 2>/dev/null | grep -Ei 'oom|Out of memory|Killed process|Memory cgroup' | tail -40; then
        :
      else
        if ! dmesg 2>"${OUT_DIR}/${LABEL}-dmesg.err" | grep -Ei 'oom|Out of memory|Killed process|Memory cgroup' | tail -40; then
          if [[ -s "${OUT_DIR}/${LABEL}-dmesg.err" ]]; then
            echo "(dmesg unavailable: $(tr '\n' ' ' <"${OUT_DIR}/${LABEL}-dmesg.err"))"
          else
            echo "(no matching OOM lines in readable dmesg buffer)"
          fi
        fi
      fi
    else
      echo "(dmesg not installed)"
    fi

    echo "=== end memory-report ${LABEL} ==="
  } | tee "$out"

  append_sample >/dev/null
  echo "Wrote memory report $out"
}

case "$MODE" in
  full)
    full_report
    ;;
  sample)
    append_sample | tee -a "${OUT_DIR}/heartbeat-memory.txt"
    ;;
  summary)
    write_summary
    ;;
  *)
    echo "usage: memory-report.sh {full|sample|summary} [label]" >&2
    exit 2
    ;;
esac
