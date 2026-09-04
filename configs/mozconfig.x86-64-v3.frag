# Phase 3: Windows x64 CPU baseline x86-64-v3 (overlay).
# Appended after upstream LibreWolf/bsys6 mozconfig composition.
#
# C/C++: env CFLAGS/CXXFLAGS become Firefox OS_CFLAGS/OS_CXXFLAGS (target).
#        Host tools use HOST_CFLAGS/HOST_CXXFLAGS — do NOT set -march here.
# Rust:  env RUSTFLAGS feeds target recipes; rust.mk HOST_RECIPES reset
#        RUSTFLAGS to rustflags_override only (no target-cpu leakage).
#
# Proven mechanisms (pinned clang 21.1.8 / rustc 1.97.1, windows-msvc):
#   -march=x86-64-v3
#   -C target-cpu=x86-64-v3

# LWPB_PHASE3_X86_64_V3
export CFLAGS="${CFLAGS:+${CFLAGS} }-march=x86-64-v3"
export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-march=x86-64-v3"
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C target-cpu=x86-64-v3"
