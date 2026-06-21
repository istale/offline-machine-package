#!/usr/bin/env bash
# scripts/hub/upload-uv.sh
# Publish uv-bundle into raw-bundles/uv/ + update latest.tar.gz alias.
set -euo pipefail
: "${HUB_BASE:=http://127.0.0.1:8081}"
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <uv-bundle-*.tar.gz>}"
[[ -f "$TARBALL" ]] || { echo "missing $TARBALL"; exit 1; }

FNAME="$(basename "$TARBALL")"
DEST="$HUB_BASE/repository/raw-bundles/uv/$FNAME"
LATEST="$HUB_BASE/repository/raw-bundles/uv/latest.tar.gz"

echo "[uv] uploading → $DEST"
curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$TARBALL" "$DEST"

echo "[uv] updating alias → $LATEST"
curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$TARBALL" "$LATEST"

echo "[uv] ✅ done. Clients install via scripts/client/install-uv.sh"
