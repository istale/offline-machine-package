#!/usr/bin/env bash
# prepare-nexus-image.sh
# 在 Mac (Apple Silicon) 上跑。產出 nexus3-image.tar.gz，帶到中樞機 podman load。
# 同時順手把幾個一定會用到的 base image 也打包進來（給 docker-hosted 用）。
#
# 配合 cross-os-offline-tarball-howto.md 的精神：強制 linux/amd64。
set -euo pipefail

OUT_DIR="${OUT_DIR:-./dist}"
PLATFORM="linux/amd64"

# === 想帶哪些 image，自己加減 ===
IMAGES=(
  "docker.io/sonatype/nexus3:latest"
  "docker.io/rockylinux/rockylinux:8.10"
  "docker.io/library/python:3.12-slim"
  "docker.io/library/node:22"
  "docker.io/library/redis:7"
  "docker.io/library/postgres:16"
  # Gitea Actions runner（若中樞要跑 CI）
  "docker.io/gitea/act_runner:latest"
)
# ================================

command -v docker >/dev/null || { echo "需要 docker / OrbStack"; exit 1; }

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/images"

for img in "${IMAGES[@]}"; do
  echo "[pull] $img"
  docker pull --platform "$PLATFORM" "$img"
  # 檔名用 image 名稱，把斜線換底線
  fname="$(echo "$img" | tr '/:' '__').tar"
  echo "[save] $fname"
  docker save -o "$STAGE/images/$fname" "$img"
done

# 順便產一份 load 用 script
cat > "$STAGE/load-images.sh" <<'EOF'
#!/usr/bin/env bash
# 在中樞機跑：把所有 image 灌進 podman
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for f in "$DIR"/images/*.tar; do
  echo "[load] $f"
  podman load -i "$f"
done
podman images
EOF
chmod +x "$STAGE/load-images.sh"

OUT="$OUT_DIR/nexus3-image-bundle-$(date -u +%Y%m%d).tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo
echo "✅ 產出: $OUT"
echo "搬到中樞機後："
echo "  mkdir ~/nexus-bundle && tar -C ~/nexus-bundle -xzf $(basename "$OUT")"
echo "  cd ~/nexus-bundle && ./load-images.sh"
