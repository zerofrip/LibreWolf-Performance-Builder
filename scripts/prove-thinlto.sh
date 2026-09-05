#!/usr/bin/env bash
# Prove effective C/C++ ThinLTO from mozconfig / autoconf / compiler logs.
# Distinguishes REQUESTED vs EFFECTIVE. Fails if ThinLTO requested but unproven.
# AVX2 / binary size is NOT accepted as ThinLTO proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

MOZCONFIG="${1:-${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig}"
BUILD_LOG="${2:-${ROOT}/artifacts/logs/bsys6-build-package.log}"
COMPILER_LOG="${3:-${ROOT}/artifacts/logs/compiler-invocations.jsonl}"
OUT_JSON="${4:-${ROOT}/artifacts/thinlto-proof.json}"

mkdir -p "$(dirname "$OUT_JSON")"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -f "$MOZCONFIG" ]] || die "mozconfig missing: $MOZCONFIG"

requested_thin=false
requested_full=false
requested_cross=false
if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto=thin([[:space:]]|$)' "$MOZCONFIG" \
  || grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto=thin,' "$MOZCONFIG"; then
  requested_thin=true
fi
# Reject accidental full/cross in same file
if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto=.*full' "$MOZCONFIG"; then
  requested_full=true
fi
if grep -Eq '^[[:space:]]*ac_add_options[[:space:]]+--enable-lto=.*cross' "$MOZCONFIG"; then
  requested_cross=true
fi

AUTOCONF=""
for cand in \
  "${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config/autoconf.mk" \
  "${WORKDIR}/librewolf-${LWPB_FULL_VERSION}"/obj-*/config/autoconf.mk
do
  if [[ -f "$cand" ]]; then AUTOCONF="$cand"; break; fi
done

moz_lto=false
moz_lto_cflags_thin=false
moz_lto_cflags_full=false
moz_lto_rust_cross=""
has_flto_thin_cflags=false

if [[ -n "$AUTOCONF" && -f "$AUTOCONF" ]]; then
  if grep -Eq '^MOZ_LTO[[:space:]]*=[[:space:]]*1' "$AUTOCONF" \
    || grep -Eq '^MOZ_LTO[[:space:]]*=[[:space:]]*true' "$AUTOCONF"; then
    moz_lto=true
  fi
  # MOZ_LTO_CFLAGS may be multi-token
  if grep -E '^MOZ_LTO_CFLAGS' "$AUTOCONF" | grep -Eq -- '-flto=thin'; then
    moz_lto_cflags_thin=true
    has_flto_thin_cflags=true
  fi
  if grep -E '^MOZ_LTO_CFLAGS' "$AUTOCONF" | grep -Eq -- '-flto([^=]|$)' \
    && ! grep -E '^MOZ_LTO_CFLAGS' "$AUTOCONF" | grep -Eq -- '-flto=thin'; then
    # bare -flto without =thin is full for clang-cl
    moz_lto_cflags_full=true
  fi
  moz_lto_rust_cross="$(grep -E '^MOZ_LTO_RUST_CROSS' "$AUTOCONF" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d ' \t\r' || true)"
fi

# Configure log evidence
configure_thin=false
if [[ -f "$BUILD_LOG" ]]; then
  if grep -E 'Adding configure options|^\s+--enable-lto' "$BUILD_LOG" | grep -Eq -- '--enable-lto=thin'; then
    configure_thin=true
  fi
fi

# Compiler invocations: clang-cl with -flto=thin (and preferably -march=x86-64-v3)
inv_thin=false
inv_full=false
inv_thin_with_v3=false
if [[ -f "$COMPILER_LOG" ]]; then
  eval "$(python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
thin=full=thin_v3=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    kind=o.get("kind") or ""
    argv=o.get("argv") or []
    joined=" ".join(argv)
    is_cl = kind=="clang-cl" or (argv and str(argv[0]).endswith("clang-cl"))
    if not is_cl and kind not in ("clang","clangxx","cc","cxx"):
        continue
    # target compiles only
    if kind in ("clang","clangxx") and "windows-msvc" not in joined and not is_cl:
        continue
    if "-flto=thin" in joined:
        thin=True
        if "-march=x86-64-v3" in joined:
            thin_v3=True
    elif " -flto" in (" "+joined) or joined.startswith("-flto") or " -flto " in joined:
        if "-flto=thin" not in joined:
            full=True
print(f"inv_thin={'true' if thin else 'false'}")
print(f"inv_full={'true' if full else 'false'}")
print(f"inv_thin_with_v3={'true' if thin_v3 else 'false'}")
PY
)"
fi

effective_mode="false"
if [[ "$moz_lto_cflags_thin" == true || "$has_flto_thin_cflags" == true ]]; then
  if [[ "$inv_thin" == true || "$configure_thin" == true ]]; then
    effective_mode="thin"
  elif [[ "$moz_lto" == true && "$moz_lto_cflags_thin" == true ]]; then
    # configure-effective ThinLTO even if invocation log sparse
    effective_mode="thin"
  fi
fi
if [[ "$moz_lto_cflags_full" == true || "$inv_full" == true ]]; then
  if [[ "$effective_mode" != "thin" ]]; then
    effective_mode="full"
  fi
fi

rust_cross_ok=true
if [[ -n "$moz_lto_rust_cross" && "$moz_lto_rust_cross" != "0" && "$moz_lto_rust_cross" != "" ]]; then
  # empty string means no cross; thin/full means cross-language LTO active
  if [[ "$moz_lto_rust_cross" == "thin" || "$moz_lto_rust_cross" == "full" ]]; then
    rust_cross_ok=false
  fi
fi

# Proven ThinLTO requires: requested thin, not full/cross, effective thin, rust cross off
proven=false
if [[ "$requested_thin" == true \
  && "$requested_full" != true \
  && "$requested_cross" != true \
  && "$effective_mode" == "thin" \
  && "$rust_cross_ok" == true \
  && "$inv_full" != true ]]; then
  # Prefer invocation evidence; allow configure+autoconf if invocations missing but MOZ_LTO_CFLAGS proven
  if [[ "$inv_thin" == true || ( "$moz_lto" == true && "$moz_lto_cflags_thin" == true && "$configure_thin" == true ) ]]; then
    proven=true
  fi
fi

# Stricter: require at least autoconf -flto=thin AND (invocations OR configure line)
if [[ "$proven" == true && "$moz_lto_cflags_thin" != true ]]; then
  proven=false
fi

jq -n \
  --argjson requested_thin "$requested_thin" \
  --argjson requested_full "$requested_full" \
  --argjson requested_cross "$requested_cross" \
  --arg autoconf "${AUTOCONF}" \
  --argjson moz_lto "$moz_lto" \
  --argjson moz_lto_cflags_thin "$moz_lto_cflags_thin" \
  --argjson moz_lto_cflags_full "$moz_lto_cflags_full" \
  --arg rust_cross "${moz_lto_rust_cross}" \
  --argjson configure_thin "$configure_thin" \
  --argjson inv_thin "$inv_thin" \
  --argjson inv_full "$inv_full" \
  --argjson inv_thin_with_v3 "$inv_thin_with_v3" \
  --arg effective "$effective_mode" \
  --argjson rust_cross_ok "$rust_cross_ok" \
  --argjson proven "$proven" \
  --arg note "Binary size / AVX2 opcodes are NOT ThinLTO proof" \
  '{
    requested: {
      cpp_lto_mode: (if $requested_thin then "thin" elif $requested_full then "full" else "none" end),
      full_lto: $requested_full,
      cross_language_lto: $requested_cross
    },
    autoconf_mk: $autoconf,
    configure_effective: {
      MOZ_LTO: $moz_lto,
      MOZ_LTO_CFLAGS_has_flto_thin: $moz_lto_cflags_thin,
      MOZ_LTO_CFLAGS_has_full_flto: $moz_lto_cflags_full,
      MOZ_LTO_RUST_CROSS: (if $rust_cross=="" then null else $rust_cross end),
      configure_log_enable_lto_thin: $configure_thin
    },
    invocations: {
      clang_cl_flto_thin: $inv_thin,
      clang_cl_flto_full: $inv_full,
      flto_thin_with_march_v3: $inv_thin_with_v3
    },
    effective_cpp_lto: (if $effective=="false" then false else $effective end),
    full_lto: ($requested_full or $moz_lto_cflags_full or $inv_full),
    rust_cross_language_lto_inactive: $rust_cross_ok,
    proven: { thinlto: $proven },
    thinlto: $proven,
    note: $note
  }' | tee "$OUT_JSON"

echo "Wrote $OUT_JSON"

if [[ "$proven" != true ]]; then
  echo "PROVE_THINLTO=FAIL" >&2
  jq . "$OUT_JSON" >&2
  exit 1
fi
echo "PROVE_THINLTO=PASS"
