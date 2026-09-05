# Phase 4: C/C++ ThinLTO overlay for Windows target.
# Use thin ONLY — never full. Do NOT pass "cross" (would set MOZ_LTO_RUST_CROSS
# and change upstream gkrust -Clto semantics from rust.mk).
#
# LWPB_PHASE4_THINLTO
ac_add_options --enable-lto=thin
