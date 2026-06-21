#!/usr/bin/env bash
# scripts/hub/extract-mega-bundle.sh
# Reverse of package-mega-bundle.sh. Accepts either:
#   - a single offline-machine-package-MEGA-*.tar.gz
#   - the .part00 .part01 ... pieces (auto-concat)
# Drops the repo into ~/offline-machine-package and the bundles into ~/inbox/.
set -euo pipefail

TARGET="${TARGET:-$HOME}"
TARBALL_OR_PART1="${1:?usage: $0 <mega.tar.gz | first .part00 file>}"
[[ -f "$TARBALL_OR_PART1" ]] || { echo "missing $TARBALL_OR_PART1"; exit 1; }

WORK="$(mktemp -d)"; trap "rm -rf $WORK" EXIT

# Handle split files
if [[ "$TARBALL_OR_PART1" == *.part* ]]; then
  BASE="${TARBALL_OR_PART1%.part*}"
  echo "[mega] reassembling parts ${BASE}.part*"
  cat "${BASE}".part* > "$WORK/mega.tar.gz"
  TAR="$WORK/mega.tar.gz"
else
  TAR="$TARBALL_OR_PART1"
fi

# Verify checksum if .sha256 sits next to the input
SHA="${TARBALL_OR_PART1%%.tar*}.sha256"
if [[ -f "$SHA" ]]; then
  echo "[mega] verifying checksums against $SHA"
  ( cd "$(dirname "$TARBALL_OR_PART1")" && sha256sum -c "$(basename "$SHA")" )
fi

echo "[mega] extracting"
mkdir -p "$WORK/x"
tar -C "$WORK/x" -xzf "$TAR"
NAME="$(ls "$WORK/x" | head -1)"

REPO_DST="$TARGET/offline-machine-package"
INBOX="$TARGET/inbox"
mkdir -p "$INBOX"

if [[ -d "$REPO_DST" ]]; then
  BACKUP="${REPO_DST}.bak.$(date -u +%Y%m%d-%H%M%S)"
  echo "[mega] existing $REPO_DST → $BACKUP"
  mv "$REPO_DST" "$BACKUP"
fi
mv "$WORK/x/$NAME/repo" "$REPO_DST"

echo "[mega] dist/*.tar.gz → $INBOX/"
mv "$WORK/x/$NAME/dist/"*.tar.gz "$INBOX/" 2>/dev/null || true
cp "$WORK/x/$NAME/MANIFEST.txt" "$INBOX/MEGA-MANIFEST.txt" 2>/dev/null || true

echo
echo "[mega] ✅ done"
echo "  repo:    $REPO_DST"
echo "  bundles: $INBOX/"
echo
echo "Next, follow docs/deployment-checklist.md starting at Phase B."
