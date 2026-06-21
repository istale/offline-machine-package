#!/usr/bin/env bash
# scripts/hub/upload-rpms.sh
# Upload .rpm files from an rpms-bundle into rpm-internal.
set -euo pipefail
: "${HUB_BASE:=http://127.0.0.1:8081}"
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <rpms-bundle-*.tar.gz>}"

STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"

count=0
for f in "$STAGE"/rpm/*.rpm; do
  [[ -f "$f" ]] || continue
  echo "  → $(basename "$f")"
  curl -sSf -u "$NX_USER:$NX_PASS" --upload-file "$f" \
    "$HUB_BASE/repository/rpm-internal/" || { echo "FAIL $f"; exit 1; }
  count=$((count+1))
done
echo "[rpms] uploaded $count RPMs"
