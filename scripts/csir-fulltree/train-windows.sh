#!/usr/bin/env bash
# Run LibreWolf package on Windows (WSL interop) with CSIR training workload.
# Usage: train-windows.sh <package.zip> <profile_out_dir> <stage_label>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
source "${ROOT}/scripts/csir-fulltree/common.sh"

PKG="${1:?package.zip}"
PROF_OUT="${2:?profile_out_dir}"
STAGE="${3:-train}"
WORKLOAD="${ROOT}/workloads/csir-train"
RUNS="${LWPB_CSIR_TRAIN_RUNS:-1}"

require_file "$PKG"
require_file "${WORKLOAD}/index.html"
require_windows_interop

mkdir -p "$PROF_OUT"
# Fresh profile dir: remove prior raw files only inside this out dir
find "$PROF_OUT" -maxdepth 1 -type f -name '*.profraw' -delete 2>/dev/null || true

STAGE_WIN="${WIN_TRAIN_ROOT}/${STAGE}-${RUN_ID}"
rm -rf "$STAGE_WIN"
mkdir -p "$STAGE_WIN/app" "$STAGE_WIN/profiles" "$STAGE_WIN/workload"

unzip -qo "$PKG" -d "$STAGE_WIN/app"
require_file "$STAGE_WIN/app/librewolf/librewolf.exe"
cp -a "$WORKLOAD/." "$STAGE_WIN/workload/"

# file:/// URL for workload (Windows path)
WL_WIN="$(wslpath -w "$STAGE_WIN/workload/index.html")"
# file:///C:/...
WL_URL="file:///$(echo "$WL_WIN" | sed 's|\\|/|g')"

EXE_WIN_DIR="$(wslpath -w "$STAGE_WIN/app/librewolf")"
PROF_WIN="$(wslpath -w "$STAGE_WIN/profiles")"
# LLVM profile pattern: pid + unique signature
PROF_PAT="${PROF_WIN}\\csir-%p-%m.profraw"

WORKLOAD_HASH="$( (cd "$WORKLOAD" && find . -type f | sort | xargs sha256sum) | sha256sum | awk '{print $1}' )"

for ((i=1; i<=RUNS; i++)); do
  echo "-> Training run $i/$RUNS stage=$STAGE"
  set +e
  /mnt/c/Windows/System32/cmd.exe /c \
    "cd /d ${EXE_WIN_DIR} && set MOZ_HEADLESS=1&& set MOZ_DISABLE_CONTENT_SANDBOX=1&& set LLVM_PROFILE_FILE=${PROF_PAT}&& librewolf.exe --headless --profile ${PROF_WIN}\\browser-profile-${i} \"${WL_URL}\" \"file:///$(echo "$(wslpath -w "$STAGE_WIN/workload/page2.html")" | sed 's|\\|/|g')\" \"file:///$(echo "$(wslpath -w "$STAGE_WIN/workload/dom.html")" | sed 's|\\|/|g')\""
  RC=$?
  set -e
  echo "browser_exit=${RC}"
done

# Collect profraw back to Linux path
mapfile -t RAWS < <(find "$STAGE_WIN/profiles" -type f -name '*.profraw' | sort)
if [[ "${#RAWS[@]}" -eq 0 ]]; then
  echo "ERROR: no .profraw produced under $STAGE_WIN/profiles" >&2
  find "$STAGE_WIN" -type f | head -50 >&2 || true
  exit 1
fi

cp -f "${RAWS[@]}" "$PROF_OUT/"
TOTAL=0
MANIFEST="${META_DIR}/${STAGE}-profraw-manifest.txt"
: >"$MANIFEST"
for f in "${RAWS[@]}"; do
  sz="$(stat -c%s "$f")"
  TOTAL=$((TOTAL + sz))
  echo "$(basename "$f") $(sha256sum "$f" | awk '{print $1}') ${sz}" >>"$MANIFEST"
  [[ "$sz" -gt 0 ]] || { echo "ERROR: empty $f" >&2; exit 1; }
done

# Validate format via docker llvm tooling if available
FIRST="$(ls "$PROF_OUT"/*.profraw | head -1)"
file "$FIRST" | tee "${META_DIR}/${STAGE}-profraw-file.txt"
grep -Eiq 'LLVM raw profile|llvm.*profile' "${META_DIR}/${STAGE}-profraw-file.txt" \
  || echo "WARN: file(1) did not label LLVM raw profile; continuing with merge gate"

write_stage_meta "${META_DIR}/${STAGE}-train.json" \
  --arg stage "$STAGE" \
  --arg workload_hash "$WORKLOAD_HASH" \
  --arg windows_ver "$(/mnt/c/Windows/System32/cmd.exe /c ver 2>/dev/null | tr -d '\r' | tail -1 || true)" \
  --argjson runs "$RUNS" \
  --argjson file_count "${#RAWS[@]}" \
  --argjson total_bytes "$TOTAL" \
  --arg profile_dir "$PROF_OUT" \
  --arg package_sha "$(json_sha256 "$PKG")" \
  '{stage:$stage,workload_hash:$workload_hash,windows:$windows_ver,runs:$runs,profraw_count:$file_count,profraw_total_bytes:$total_bytes,profile_dir:$profile_dir,package_sha256:$package_sha,deterministic:true,network_dependency:false}'

echo "Training complete: ${#RAWS[@]} profraw files, ${TOTAL} bytes"
