#!/usr/bin/env bash
# Lightweight Phase 6 validation (no full LibreWolf build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p artifacts/csir-fulltree/local-validate

echo "== Phase 6 local validate =="

bash -n scripts/csir-fulltree/common.sh
bash -n scripts/csir-fulltree/build-stage-a.sh
bash -n scripts/csir-fulltree/build-stage-b.sh
bash -n scripts/csir-fulltree/build-stage-d.sh
bash -n scripts/csir-fulltree/train-windows.sh
bash -n scripts/csir-fulltree/merge-base.sh
bash -n scripts/csir-fulltree/merge-combined.sh
bash -n scripts/csir-fulltree/apply-stage-b-mozconfig.sh
bash -n scripts/csir-fulltree/preflight-stage-b.sh
bash -n scripts/csir-fulltree/prove-csir-fulltree.sh
bash -n scripts/csir-fulltree/smoke-windows.sh
bash -n scripts/csir-fulltree/normalize-base-profdata.sh
bash -n scripts/csir-fulltree/test-base-artifact-layout.sh
bash -n scripts/csir-fulltree/test-profile-generate-gate.sh

command -v jq >/dev/null
jq -e '.phase == "6-csir-fulltree"' configs/phase6-csir-fulltree.contract.json
jq -e '.upstream_windows_profdata_as_stage_a == false' configs/phase6-csir-fulltree.contract.json
jq -e '.final_expected.thinlto == true' configs/phase6-csir-fulltree.contract.json

grep -q 'LWPB_PHASE6_CSIR_BASE_GEN' configs/mozconfig.csir-base-gen.frag
grep -q 'enable-profile-generate' configs/mozconfig.csir-base-gen.frag
grep -q 'LWPB_PHASE6_CSIR_CS_GEN' configs/mozconfig.csir-cs-gen.frag
grep -q 'LWPB_PHASE6_CSIR_FINAL' configs/mozconfig.csir-final.frag
grep -q 'normalize-base-profdata.sh' .github/workflows/csir-fulltree.yml

# Workload present + deterministic hash
test -f workloads/csir-train/index.html
test -f workloads/csir-train/train.js
WL_HASH="$( (cd workloads/csir-train && find . -type f | sort | xargs sha256sum) | sha256sum | awk '{print $1}' )"
echo "workload_hash=${WL_HASH}"

# Privacy must pass
bash scripts/check-privacy-invariants.sh

# Document integration map exists
test -f docs/PHASE6-INTEGRATION.md
grep -qi 'own matching LibreWolf IR profile' docs/PHASE6-INTEGRATION.md

# Artifact layout normalization (requires authoritative base.profdata on disk)
if [[ -s artifacts/csir-fulltree/runs/20260905TPhase6A/profiles/base.profdata ]]; then
  bash scripts/csir-fulltree/test-base-artifact-layout.sh \
    | tee artifacts/csir-fulltree/local-validate/base-artifact-layout.txt
  bash scripts/csir-fulltree/test-profile-generate-gate.sh \
    | tee artifacts/csir-fulltree/local-validate/profile-generate-gate.txt
else
  echo "ERROR: authoritative base.profdata missing for layout tests" >&2
  exit 1
fi

# Upstream windows.profdata must not be Stage B authority (disable helper present)
grep -q 'disable_upstream_profdata_asset' scripts/csir-fulltree/common.sh
grep -Eq 'windows\.profdata\.lwpb-phase6-disabled|lwpb-phase6-disabled' \
  scripts/csir-fulltree/common.sh scripts/csir-fulltree/build-stage-b.sh

# Probe CSIR flags if docker image available (optional)
if command -v docker >/dev/null 2>&1 \
  && docker image inspect codeberg.org/librewolf/bsys6:windows >/dev/null 2>&1; then
  bash scripts/csir-poc/probe-csir-flags.sh \
    | tee artifacts/csir-fulltree/local-validate/csir-flags.txt
else
  echo "NOTE: docker/bsys6 image absent — skipped CSIR flag probe"
fi

# Confirm bsys6 injection knowledge encoded in common.sh
grep -q 'disable_upstream_profdata_asset' scripts/csir-fulltree/common.sh

echo "PHASE6_LOCAL_VALIDATE=PASS"


