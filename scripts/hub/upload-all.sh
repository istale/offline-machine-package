#!/usr/bin/env bash
# scripts/hub/upload-all.sh
# Convenience: run every upload-* for the newest matching tarball in dist/.
# Requires: HUB_BASE, NX_USER, NX_PASS, DOCKER_HOST_REG, GITEA_BASE, GITEA_TOKEN
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-$HERE/../../dist}"

latest() { ls -1t "$DIST"/$1 2>/dev/null | head -1 || true; }

run_if() {
  local script="$1" glob="$2"
  local f; f=$(latest "$glob")
  if [[ -n "$f" ]]; then echo "=== $script $f ==="; "$HERE/$script" "$f"; else echo "skip $script (no $glob)"; fi
}

run_if upload-pypi.sh   'pypi-bundle-*.tar.gz'
run_if upload-npm.sh    'npm-bundle-*.tar.gz'
run_if upload-images.sh 'images-bundle-*.tar.gz'
run_if upload-rpms.sh   'rpms-bundle-*.tar.gz'
run_if upload-repos.sh  'repos-bundle-*.tar.gz'
run_if upload-uv.sh     'uv-bundle-*.tar.gz'
run_if upload-hermes.sh 'hermes-bundle-*.tar.gz'
echo "[hub] upload-all done"
