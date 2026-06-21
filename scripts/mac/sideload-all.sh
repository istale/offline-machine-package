#!/usr/bin/env bash
# scripts/mac/sideload-all.sh
# Convenience: run every sideload-* script. Skips ones whose manifest is empty.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for s in sideload-pypi.sh sideload-npm.sh sideload-images.sh sideload-repos.sh sideload-rpms.sh sideload-uv.sh sideload-hermes.sh; do
  echo
  echo "=== $s ==="
  "$HERE/$s" || { echo "[FAIL] $s"; exit 1; }
done
echo
echo "All bundles in dist/. Ship to hub machine."
ls -lh "$HERE/../../dist/" 2>/dev/null || true
