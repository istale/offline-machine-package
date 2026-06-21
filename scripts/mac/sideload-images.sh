#!/usr/bin/env bash
# scripts/mac/sideload-images.sh
# Reads manifests/images.txt, docker pull --platform linux/amd64, docker save.
# Produces dist/images-bundle-*.tar.gz + a load-images.sh inside the tarball.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/images.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
PLATFORM="linux/amd64"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
mapfile -t IMAGES < <(grep -vE '^\s*(#|$)' "$MANIFEST")
[[ ${#IMAGES[@]} -gt 0 ]] || { echo "manifest is empty"; exit 0; }

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/images"

for img in "${IMAGES[@]}"; do
  echo "[images] pull $img"
  docker pull --platform "$PLATFORM" "$img"
  fname="$(echo "$img" | tr '/:' '__').tar"
  docker save -o "$STAGE/images/$fname" "$img"
done

cat > "$STAGE/load-images.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for f in "$DIR"/images/*.tar; do echo "[load] $f"; podman load -i "$f"; done
podman images
EOF
chmod +x "$STAGE/load-images.sh"

OUT="$OUT_DIR/images-bundle-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo "[images] produced: $OUT"
