#!/usr/bin/env bash
# Invoked inside bsys6:windows image. Args: <out_relpath> <cflags...>
set -euo pipefail
export PATH="/root/.mozbuild/clang/bin:${PATH}"

OUT_REL="${1:?}"
shift
CFLAGS=("$@")

VS=/root/.mozbuild/win-cross/vs
MSVC="${VS}/VC/Tools/MSVC/14.50.35717"
SDKVER=10.0.26100.0
SDK="${VS}/Windows Kits/10"
RT=/root/.mozbuild/clang/lib/clang/21/lib/windows
TARGET="${LWPB_WINDOWS_TARGET_X64:-x86_64-pc-windows-msvc}"

OUT="/src/${OUT_REL}"
OBJ=/tmp/csir_poc.obj
mkdir -p "$(dirname "$OUT")"

clang-cl -fms-compatibility-version=19.50 --target="${TARGET}" \
  -imsvc "${MSVC}/include" \
  -imsvc "${SDK}/Include/${SDKVER}/ucrt" \
  -imsvc "${SDK}/Include/${SDKVER}/shared" \
  -imsvc "${SDK}/Include/${SDKVER}/um" \
  "${CFLAGS[@]}" \
  /src/tests/csir-poc/csir_poc.c -c -Fo"${OBJ}"

LINK_LIBS=()
JOINED=" ${CFLAGS[*]} "
if [[ "$JOINED" == *"fprofile-generate"* || "$JOINED" == *"fcs-profile-generate"* ]]; then
  LINK_LIBS+=("${RT}/clang_rt.profile-x86_64.lib")
fi

# ThinLTO objects need lto enabled at link
LTO_ARGS=()
if [[ "$JOINED" == *"flto=thin"* || "$JOINED" == *" -flto "* ]]; then
  LTO_ARGS+=("-lldltocache:/tmp/lldltocache")
fi

lld-link -out:"${OUT}" "${OBJ}" \
  "-libpath:${MSVC}/lib/x64" \
  "-libpath:${SDK}/Lib/${SDKVER}/ucrt/x64" \
  "-libpath:${SDK}/Lib/${SDKVER}/um/x64" \
  "-libpath:${RT}" \
  "${LINK_LIBS[@]}" \
  "${LTO_ARGS[@]}" \
  -defaultlib:libcmt \
  -defaultlib:oldnames

file "${OUT}"
clang --version | head -1
llvm-profdata --version 2>&1 | head -2
