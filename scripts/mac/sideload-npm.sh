#!/usr/bin/env bash
# scripts/mac/sideload-npm.sh
# Reads manifests/npm.txt, npm pack inside Rocky 8.10 container.
# Produces dist/npm-bundle-*.tar.gz.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/npm.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
PLATFORM="linux/amd64"
IMAGE="rockylinux/rockylinux:8.10"
NODE_MAJOR="${NODE_MAJOR:-22}"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
SPECS=$(grep -vE '^\s*(#|$)' "$MANIFEST" | tr '\n' ' ')
[[ -n "$SPECS" ]] || { echo "manifest is empty"; exit 0; }

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/npm"

echo "[npm] packing inside $IMAGE: $SPECS"
docker run --rm --platform "$PLATFORM" \
  -v "$STAGE/npm":/out -w /out \
  "$IMAGE" bash -c "
    set -e
    curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash - >/dev/null 2>&1
    dnf install -y --quiet nodejs >/dev/null
    for p in $SPECS; do npm pack \"\$p\"; done
  "

OUT="$OUT_DIR/npm-bundle-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo "[npm] produced: $OUT"
