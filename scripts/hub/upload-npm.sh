#!/usr/bin/env bash
# scripts/hub/upload-npm.sh
# Upload all .tgz inside an npm-bundle tarball to npm-internal.
set -euo pipefail
: "${HUB_BASE:=http://127.0.0.1:8081}"
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <npm-bundle-*.tar.gz>}"

STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"

count=0
for f in "$STAGE"/npm/*.tgz; do
  [[ -f "$f" ]] || continue
  echo "  → $(basename "$f")"
  curl -sSf -u "$NX_USER:$NX_PASS" -H 'Content-Type: application/octet-stream' \
    --upload-file "$f" "$HUB_BASE/repository/npm-internal/" || { echo "FAIL $f"; exit 1; }
  count=$((count+1))
done
echo "[npm] uploaded $count files to npm-internal"
