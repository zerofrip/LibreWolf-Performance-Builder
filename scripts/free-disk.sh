#!/usr/bin/env bash
# Reclaim disk on GitHub-hosted Ubuntu runners (inspired by community Firefox builders).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "-> Freeing disk space (best-effort)"
sudo rm -rf \
  /usr/local/lib/android \
  /usr/share/dotnet \
  /opt/ghc \
  /opt/hostedtoolcache/CodeQL \
  /usr/local/share/boost \
  /usr/share/swift \
  "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}/CodeQL" \
  2>/dev/null || true

sudo docker image prune --all --force 2>/dev/null || true

"${ROOT}/scripts/disk-report.sh" after-cleanup
