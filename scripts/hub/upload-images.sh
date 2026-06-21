#!/usr/bin/env bash
# scripts/hub/upload-images.sh
# Load .tar images from an images-bundle and push them all into docker-hosted.
set -euo pipefail
: "${DOCKER_HOST_REG:=127.0.0.1:8082}"   # NB: not DOCKER_HOST (env collision with docker CLI)
: "${NX_USER:?export NX_USER}"
: "${NX_PASS:?export NX_PASS}"
TARBALL="${1:?usage: $0 <images-bundle-*.tar.gz>}"

STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"

for f in "$STAGE"/images/*.tar; do
  [[ -f "$f" ]] || continue
  echo "[load] $f"; podman load -i "$f"
done

podman login -u "$NX_USER" -p "$NX_PASS" "$DOCKER_HOST_REG" --tls-verify=false

# Re-tag every loaded image to point at the hub registry and push.
mapfile -t REFS < <(podman images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
for ref in "${REFS[@]}"; do
  # strip docker.io/ and library/ for cleaner names on the hub
  short="${ref#docker.io/}"; short="${short#library/}"
  newref="${DOCKER_HOST_REG}/${short}"
  echo "  → push $newref"
  podman tag "$ref" "$newref"
  podman push --tls-verify=false "$newref"
done
echo "[images] done"
