#!/usr/bin/env bash
# scripts/mac/sideload-hermes.sh
# Runs the upstream Hermes Agent install.sh inside a Rocky 8.10 / amd64
# container, then snapshots the THREE paths the installer actually writes:
#   /opt/hermes               (config + runtime data)
#   /usr/local/lib/hermes-agent  (code: node_modules, venv, repo)
#   /usr/local/bin/hermes     (entry symlink)
# Bundles them under stage/{opt,usrlocal-lib,usrlocal-bin} for the client
# installer to put back in place.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/hermes.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
PLATFORM="linux/amd64"
IMAGE="rockylinux/rockylinux:8.10"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
# shellcheck disable=SC1090
source "$MANIFEST"
: "${HERMES_REF:=main}"

mkdir -p "$OUT_DIR"
STAGE="$ROOT/workspace/hermes-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Write the in-container install logic as a real file. Mounted into the
# container; no nested quoting required.
INNER="$ROOT/workspace/hermes-inner.sh"
cat > "$INNER" <<'INNER_EOF'
#!/usr/bin/env bash
set -euxo pipefail

dnf install -y --quiet --setopt=install_weak_deps=False \
  git curl tar xz which findutils make gcc \
  python3.12 python3.12-pip python3-devel libffi-devel \
  nss atk at-spi2-atk cups-libs libdrm libxkbcommon mesa-libgbm \
  alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver \
  rsync

# upstream installer is non-interactive when stdin isn't a TTY (it prints
# "Setup wizard skipped"), so just pipe via curl|bash equivalent.
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/install.sh
bash /tmp/install.sh

# pin to requested ref if not main
if [[ "${HERMES_REF}" != "main" && -d /usr/local/lib/hermes-agent/.git ]]; then
  git -C /usr/local/lib/hermes-agent fetch --tags origin
  git -C /usr/local/lib/hermes-agent checkout "${HERMES_REF}"
fi

# Snapshot the three paths into /stage
mkdir -p /stage/opt /stage/usrlocal-lib /stage/usrlocal-bin
[[ -d /opt/hermes ]] && rsync -a /opt/hermes/ /stage/opt/hermes/
[[ -d /usr/local/lib/hermes-agent ]] && rsync -a /usr/local/lib/hermes-agent/ /stage/usrlocal-lib/hermes-agent/
# preserve symlink as-is
if [[ -L /usr/local/bin/hermes || -f /usr/local/bin/hermes ]]; then
  cp -a /usr/local/bin/hermes /stage/usrlocal-bin/hermes
fi

# Record build info
{
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hermes_ref=${HERMES_REF}"
  (cd /usr/local/lib/hermes-agent 2>/dev/null && echo "commit=$(git rev-parse HEAD)") || true
  echo "container=$(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)"
} > /stage/BUILD_INFO
INNER_EOF
chmod +x "$INNER"

echo "[hermes] building inside $IMAGE (ref=$HERMES_REF)"
docker run --rm --platform "$PLATFORM" \
  -v "$STAGE":/stage \
  -v "$INNER":/tmp/inner.sh:ro \
  -e HERMES_REF="$HERMES_REF" \
  -e HERMES_NONINTERACTIVE=1 \
  "$IMAGE" bash /tmp/inner.sh

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/hermes-bundle-${STAMP}.tar.gz"
echo "[hermes] packing → $OUT"
tar --owner=0 --group=0 -C "$STAGE" -czf "$OUT" .

echo
echo "[hermes] ✅ produced: $OUT"
echo "[hermes] build info:"
cat "$STAGE/BUILD_INFO" 2>/dev/null || true
echo
echo "Ship to hub, then on hub: ./scripts/hub/upload-hermes.sh $OUT"
echo "On offline desktop:        sudo ./scripts/client/install-hermes.sh"
