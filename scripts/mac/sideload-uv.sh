#!/usr/bin/env bash
# scripts/mac/sideload-uv.sh
# Downloads the uv static binary (linux x86_64, glibc target) from GitHub
# releases and bundles it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/uv.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
# shellcheck disable=SC1090
source "$MANIFEST"
: "${UV_VERSION:=latest}"
: "${UV_ARCH:=x86_64-unknown-linux-gnu}"

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/uv"

# Resolve version
if [[ "$UV_VERSION" == "latest" ]]; then
  echo "[uv] resolving latest tag from GitHub"
  TAG=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | \
    grep -oE '"tag_name": *"[^"]+"' | head -1 | cut -d'"' -f4)
  [[ -n "$TAG" ]] || { echo "could not resolve latest tag"; exit 1; }
else
  TAG="$UV_VERSION"
fi
echo "[uv] version: $TAG  arch: $UV_ARCH"

URL="https://github.com/astral-sh/uv/releases/download/${TAG}/uv-${UV_ARCH}.tar.gz"
echo "[uv] downloading $URL"
curl -fsSL "$URL" -o "$STAGE/uv/uv.tar.gz"

# Extract to sanity-check + flatten layout
( cd "$STAGE/uv" && tar -xzf uv.tar.gz )
INNER=$(find "$STAGE/uv" -maxdepth 2 -type f -name uv -perm -u+x | head -1)
[[ -x "$INNER" ]] || { echo "uv binary missing in tarball"; ls -R "$STAGE/uv"; exit 1; }
"$INNER" --version || true   # Mac can't actually run linux binary, this will fail; harmless

# Record what we shipped
{
  echo "uv_version=$TAG"
  echo "uv_arch=$UV_ARCH"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/BUILD_INFO"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/uv-bundle-${STAMP}.tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo
echo "[uv] ✅ produced: $OUT"
echo "[uv] ship to hub, then:  ./scripts/hub/upload-uv.sh $OUT"
echo "[uv] then on each offline machine:  sudo ./scripts/client/install-uv.sh"
