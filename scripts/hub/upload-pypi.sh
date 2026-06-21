#!/usr/bin/env bash
# scripts/hub/upload-pypi.sh
# On the hub. Extract a pypi-bundle tarball and curl-PUT all wheels/sdists
# into the pypi-internal hosted repo.
set -euo pipefail
: "${HUB_BASE:=http://127.0.0.1:8081}"
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <pypi-bundle-*.tar.gz>}"

STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"

count=0
for f in "$STAGE"/pypi/*.whl "$STAGE"/pypi/*.tar.gz; do
  [[ -f "$f" ]] || continue
  echo "  → $(basename "$f")"
  curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$f" \
    "$HUB_BASE/repository/pypi-internal/" || { echo "FAIL $f"; exit 1; }
  count=$((count+1))
done
echo "[pypi] uploaded $count files to pypi-internal"
