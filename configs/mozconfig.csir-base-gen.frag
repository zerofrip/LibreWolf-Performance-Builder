# Phase 6 Stage A: LibreWolf base IR profile generation (C/C++).
# Firefox disables C/C++ LTO when --enable-profile-generate is set.
# Do NOT enable-profile-use / windows.profdata here (orchestrator strips them).
#
# LWPB_PHASE6_CSIR_BASE_GEN
ac_add_options --enable-profile-generate
