#!/usr/bin/env bash
# scripts/mac/sideload-pypi.sh
# Reads manifests/pypi.txt, pip-downloads inside Rocky 8.10 container so all
# wheels are glibc 2.28 / cp312 / x86_64. Produces dist/pypi-bundle-*.tar.gz.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/pypi.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
PLATFORM="linux/amd64"
IMAGE="rockylinux/rockylinux:8.10"
PY="${PY:-python3.12}"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }

SPECS=$(grep -vE '^\s*(#|$)' "$MANIFEST" | tr '\n' ' ')
[[ -n "$SPECS" ]] || { echo "manifest is empty, nothing to do"; exit 0; }

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/pypi"

echo "[pypi] downloading inside $IMAGE: $SPECS"
docker run --rm --platform "$PLATFORM" \
  -v "$STAGE/pypi":/out \
  "$IMAGE" bash -c "
    set -e
    dnf install -y --quiet $PY ${PY}-pip >/dev/null
    $PY -m pip install --quiet --upgrade pip wheel
    $PY -m pip download --dest /out $SPECS
  "

OUT="$OUT_DIR/pypi-bundle-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$STAGE" -czf "$OUT" .

# quick contamination check (see howto §4)
BAD=$(tar -tzf "$OUT" | grep '\.whl$' | grep -E '(arm64|aarch64|macosx|win_amd64|musllinux)' || true)
[[ -z "$BAD" ]] && echo "[pypi] ✅ clean x86_64/manylinux wheels" || { echo "[pypi] ❌ contaminated:"; echo "$BAD"; exit 1; }

echo "[pypi] produced: $OUT"
