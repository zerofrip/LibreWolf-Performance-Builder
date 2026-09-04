#!/usr/bin/env bash
# Prove effective x86-64-v3 configuration from mozconfig / autoconf / compiler logs.
# Binary AVX2 presence is NOT accepted as proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-${ROOT}/work/bsys6-work}"
# shellcheck source=load-pins.sh
source "${ROOT}/scripts/load-pins.sh"

MOZCONFIG="${1:-${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/mozconfig}"
BUILD_LOG="${2:-${ROOT}/artifacts/logs/bsys6-build-package.log}"
COMPILER_LOG="${3:-${ROOT}/artifacts/logs/compiler-invocations.jsonl}"
OUT_JSON="${4:-${ROOT}/artifacts/v3-proof.json}"

mkdir -p "$(dirname "$OUT_JSON")" "${ROOT}/artifacts/logs"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$MOZCONFIG" ]] || die "mozconfig missing: $MOZCONFIG"

has_march=false
has_rust_cpu=false
grep -Eq -- '-march=x86-64-v3' "$MOZCONFIG" && has_march=true
grep -Eq -- 'target-cpu=x86-64-v3' "$MOZCONFIG" && has_rust_cpu=true

# autoconf.mk (configure-effective flags)
AUTOCONF=""
for cand in \
  "${WORKDIR}/librewolf-${LWPB_FULL_VERSION}/obj-x86_64-pc-windows-msvc/config/autoconf.mk" \
  "${WORKDIR}/librewolf-${LWPB_FULL_VERSION}"/obj-*/config/autoconf.mk
do
  if [[ -f "$cand" ]]; then AUTOCONF="$cand"; break; fi
done

os_cflags_v3=false
os_cxxflags_v3=false
host_cflags_clean=true
host_cxxflags_clean=true
rustflags_v3=false

if [[ -n "$AUTOCONF" && -f "$AUTOCONF" ]]; then
  if grep -E '^OS_CFLAGS' "$AUTOCONF" | grep -Eq -- '-march=x86-64-v3'; then os_cflags_v3=true; fi
  if grep -E '^OS_CXXFLAGS' "$AUTOCONF" | grep -Eq -- '-march=x86-64-v3'; then os_cxxflags_v3=true; fi
  if grep -E '^HOST_CFLAGS' "$AUTOCONF" | grep -Eq -- '-march=x86-64-v3'; then host_cflags_clean=false; fi
  if grep -E '^HOST_CXXFLAGS' "$AUTOCONF" | grep -Eq -- '-march=x86-64-v3'; then host_cxxflags_clean=false; fi
  if grep -E '^RUSTFLAGS' "$AUTOCONF" | grep -Eq -- 'target-cpu=x86-64-v3'; then rustflags_v3=true; fi
fi

# Compiler invocation log evidence (TARGET vs HOST)
c_target_inv=false
cxx_target_inv=false
rust_target_inv=false
host_c_leak=false
host_rust_leak=false

if [[ -f "$COMPILER_LOG" ]]; then
  # TARGET C: windows-msvc target + -march=x86-64-v3
  if python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
ok=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    argv=" ".join(o.get("argv") or [])
    kind=o.get("kind","")
    if kind not in ("clang","cc",""): 
        # also accept unknown if looks like clang
        pass
    is_win = ("x86_64-pc-windows-msvc" in argv) or ("x86_64-windows-msvc" in argv) or ("--target=x86_64-pc-windows-msvc" in argv)
    has_v3 = "-march=x86-64-v3" in argv
    is_host = ("x86_64-unknown-linux" in argv) or ("x86_64-pc-linux" in argv)
    if is_win and has_v3 and kind in ("clang","cc","unknown"):
        ok=True
    if kind in ("clang","cc") and has_v3 and is_host and not is_win:
        # host leak with march — still note via separate check below
        pass
if not ok:
    # also: kind clang with march and windows in any form
    for line in open(path):
        line=line.strip()
        if not line: continue
        try: o=json.loads(line)
        except Exception: continue
        argv=" ".join(o.get("argv") or [])
        if o.get("kind") in ("clang","cc") and "-march=x86-64-v3" in argv and ("windows-msvc" in argv or "windows-msvc" in argv.replace("_","-")):
            ok=True
            break
sys.exit(0 if ok else 1)
PY
  then c_target_inv=true; fi

  if python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
ok=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("kind") not in ("clangxx","cxx"): continue
    argv=" ".join(o.get("argv") or [])
    if "-march=x86-64-v3" in argv and ("windows-msvc" in argv):
        ok=True
        break
sys.exit(0 if ok else 1)
PY
  then cxx_target_inv=true; fi

  if python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
ok=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("kind") != "rustc": continue
    argv=" ".join(o.get("argv") or [])
    if "target-cpu=x86-64-v3" in argv and "x86_64-pc-windows-msvc" in argv:
        ok=True
        break
sys.exit(0 if ok else 1)
PY
  then rust_target_inv=true; fi

  # Host leakage: -march=x86-64-v3 without a Windows target
  if python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
leak=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("kind") not in ("clang","cc","clangxx","cxx"): continue
    argv=" ".join(o.get("argv") or [])
    if "-march=x86-64-v3" not in argv: continue
    if "windows-msvc" not in argv:
        leak=True
        break
sys.exit(0 if leak else 1)
PY
  then host_c_leak=true; fi

  if python3 - "$COMPILER_LOG" <<'PY'
import json,sys
path=sys.argv[1]
leak=False
for line in open(path):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("kind") != "rustc": continue
    argv=o.get("argv") or []
    joined=" ".join(argv)
    if "target-cpu=x86-64-v3" not in joined: continue
    # host rustc typically uses linux gnu target or no --target (defaults host)
    has_win=any("x86_64-pc-windows-msvc" in a for a in argv)
    if not has_win:
        leak=True
        break
sys.exit(0 if leak else 1)
PY
  then host_rust_leak=true; fi
fi

# Fallback: build log greps (mach sometimes echoes commands)
if [[ -f "$BUILD_LOG" ]]; then
  if [[ "$c_target_inv" != true ]]; then
    if grep -E -- '-march=x86-64-v3' "$BUILD_LOG" | grep -E 'windows-msvc|x86_64-pc-windows' | grep -Eqv 'clang\+\+|g\+\+|c\+\+'; then
      # weak: any clang-like line; treat as soft evidence only if autoconf also ok
      :
    fi
    if grep -Eq -- 'clang.*-march=x86-64-v3.*windows-msvc|clang.*windows-msvc.*-march=x86-64-v3' "$BUILD_LOG"; then
      c_target_inv=true
    fi
  fi
  if [[ "$cxx_target_inv" != true ]]; then
    if grep -Eq -- 'clang\+\+.*-march=x86-64-v3|c\+\+.*-march=x86-64-v3' "$BUILD_LOG" | head -1 | grep -q .; then
      if grep -E -- '-march=x86-64-v3' "$BUILD_LOG" | grep -E 'clang\+\+|\$CXX' | grep -Eq 'windows-msvc'; then
        cxx_target_inv=true
      fi
    fi
  fi
  if [[ "$rust_target_inv" != true ]]; then
    if grep -Eq -- 'target-cpu=x86-64-v3' "$BUILD_LOG" | head -1 | grep -q .; then
      if grep -E -- 'target-cpu=x86-64-v3' "$BUILD_LOG" | grep -Eq 'x86_64-pc-windows-msvc|windows-msvc'; then
        rust_target_inv=true
      fi
    fi
  fi
fi

# Proven rules:
# - mozconfig must request both mechanisms
# - autoconf OS_* must show v3; HOST_* must not
# - at least one TARGET invocation per language family from compiler log OR build log
# Prefer compiler log; if missing invocations but autoconf proven, still FAIL (user requires invocation evidence)

c_proven=false
cxx_proven=false
rust_proven=false
sep_proven=false

[[ "$has_march" == true && "$os_cflags_v3" == true && "$c_target_inv" == true ]] && c_proven=true
[[ "$has_march" == true && "$os_cxxflags_v3" == true && "$cxx_target_inv" == true ]] && cxx_proven=true
[[ "$has_rust_cpu" == true && "$rustflags_v3" == true && "$rust_target_inv" == true ]] && rust_proven=true
[[ "$host_cflags_clean" == true && "$host_cxxflags_clean" == true && "$host_c_leak" != true && "$host_rust_leak" != true ]] && sep_proven=true

overall=false
if [[ "$c_proven" == true && "$cxx_proven" == true && "$rust_proven" == true && "$sep_proven" == true ]]; then
  overall=true
fi

jq -n \
  --argjson requested_v3 true \
  --argjson mozconfig_march "$has_march" \
  --argjson mozconfig_rust_cpu "$has_rust_cpu" \
  --arg autoconf "${AUTOCONF}" \
  --argjson os_cflags_v3 "$os_cflags_v3" \
  --argjson os_cxxflags_v3 "$os_cxxflags_v3" \
  --argjson host_cflags_clean "$host_cflags_clean" \
  --argjson host_cxxflags_clean "$host_cxxflags_clean" \
  --argjson rustflags_v3 "$rustflags_v3" \
  --argjson c_target_inv "$c_target_inv" \
  --argjson cxx_target_inv "$cxx_target_inv" \
  --argjson rust_target_inv "$rust_target_inv" \
  --argjson host_c_leak "$host_c_leak" \
  --argjson host_rust_leak "$host_rust_leak" \
  --argjson c_proven "$c_proven" \
  --argjson cxx_proven "$cxx_proven" \
  --argjson rust_proven "$rust_proven" \
  --argjson host_target_separation "$sep_proven" \
  --argjson x86_64_v3_proven "$overall" \
  --arg note "AVX2/BMI/FMA opcode presence in the PE is NOT sufficient proof of x86-64-v3 baseline" \
  '{
    requested: { x86_64_v3: $requested_v3 },
    mozconfig: { march_x86_64_v3: $mozconfig_march, rust_target_cpu_x86_64_v3: $mozconfig_rust_cpu },
    autoconf_mk: $autoconf,
    configure_effective: {
      OS_CFLAGS_has_v3: $os_cflags_v3,
      OS_CXXFLAGS_has_v3: $os_cxxflags_v3,
      HOST_CFLAGS_clean: $host_cflags_clean,
      HOST_CXXFLAGS_clean: $host_cxxflags_clean,
      RUSTFLAGS_has_v3: $rustflags_v3
    },
    invocations: {
      c_target: $c_target_inv,
      cxx_target: $cxx_target_inv,
      rust_target: $rust_target_inv,
      host_c_march_leak: $host_c_leak,
      host_rust_target_cpu_leak: $host_rust_leak
    },
    proven: {
      c_x86_64_v3: $c_proven,
      cpp_x86_64_v3: $cxx_proven,
      rust_x86_64_v3: $rust_proven,
      host_target_separation: $host_target_separation
    },
    x86_64_v3: $x86_64_v3_proven,
    note: $note
  }' | tee "$OUT_JSON"

echo "Wrote $OUT_JSON"

if [[ "$overall" != true ]]; then
  echo "PROVE_MARCH_V3=FAIL" >&2
  jq . "$OUT_JSON" >&2
  exit 1
fi
echo "PROVE_MARCH_V3=PASS"
