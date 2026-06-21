#!/usr/bin/env bash
# scripts/hub/upload-hermes.sh
# Push a hermes-bundle tarball into Nexus raw-bundles under hermes/<filename>,
# plus a stable alias hermes/latest.tar.gz for the client installer.
set -euo pipefail
: "${HUB_BASE:=http://127.0.0.1:8081}"
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <hermes-bundle-*.tar.gz>}"
[[ -f "$TARBALL" ]] || { echo "missing $TARBALL"; exit 1; }

FNAME="$(basename "$TARBALL")"
DEST="$HUB_BASE/repository/raw-bundles/hermes/$FNAME"
LATEST="$HUB_BASE/repository/raw-bundles/hermes/latest.tar.gz"

echo "[hermes] uploading → $DEST"
curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$TARBALL" "$DEST"

echo "[hermes] updating alias → $LATEST"
curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$TARBALL" "$LATEST"

echo "[hermes] ✅ done. Clients can install via scripts/client/install-hermes.sh"
