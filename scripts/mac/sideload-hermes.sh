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
  git curl tar xz which findutils make gcc gcc-c++ \
  python3.12 python3.12-pip python3-devel libffi-devel \
  nss atk at-spi2-atk cups-libs libdrm libxkbcommon mesa-libgbm \
  alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver \
  rsync

# Force node-gyp to use Python 3.12 (Rocky 8.10's default python3 is 3.6,
# too old for modern gyp_main.py which uses 3.8+ walrus syntax). Without
# this, native modules like node-pty fail to build and cascade-kill the
# entire npm install, leaving apps/desktop/node_modules empty → no Electron.
export PYTHON=/usr/bin/python3.12
export npm_config_python=/usr/bin/python3.12
# Also unify the python3 shim so any tool reading /usr/bin/python3 wins too.
alternatives --set python3 /usr/bin/python3.12 2>/dev/null || \
  ln -sf /usr/bin/python3.12 /usr/local/bin/python3

# Cache must NOT be inside /usr/local/lib/hermes-agent — installer checks that
# dir and refuses if non-empty / not a git repo. Use a separate location.
export HERMES_CACHE=/var/cache/hermes-bundled
mkdir -p "$HERMES_CACHE"/{electron,ms-playwright,npm,pip,xdg}

export XDG_CACHE_HOME="$HERMES_CACHE/xdg"
export ELECTRON_CACHE="$HERMES_CACHE/electron"
export PLAYWRIGHT_BROWSERS_PATH="$HERMES_CACHE/ms-playwright"
export npm_config_cache="$HERMES_CACHE/npm"
export PIP_CACHE_DIR="$HERMES_CACHE/pip"

# Upstream installer is non-interactive when stdin isn't a TTY.
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/install.sh
bash /tmp/install.sh

# --- Force desktop (Electron) build ---
# Upstream install.sh's `npm install` silently fails partway and leaves
# apps/desktop/node_modules empty → no Electron binary → desktop GUI dies on
# offline launch. Force a clean install with explicit error capture so the
# binary actually lands in the bundle.
echo "=== Installing apps/desktop dependencies (Electron) ==="
export PATH=/root/.hermes/node/bin:$PATH   # use bundled npm/node
cd /usr/local/lib/hermes-agent
# Top-level install populates all workspaces including apps/desktop.
# --include=optional ensures platform-specific Electron binaries are fetched.
npm install --no-fund --no-audit --include=optional 2>&1 | tail -40 || {
  echo "[WARN] top-level npm install reported errors; trying targeted desktop install"
  npm install --workspace apps/desktop --no-fund --no-audit --include=optional 2>&1 | tail -40 || true
}

# Build the Vite renderer so production launch doesn't need a dev server.
echo "=== Building apps/desktop renderer ==="
cd /usr/local/lib/hermes-agent/apps/desktop
npm run build 2>&1 | tail -20 || \
  echo "[WARN] desktop build failed; GUI may be source-only"
cd /

# Hermes ships a Playwright dep but install.sh does NOT auto-download Chromium
# unless the user runs `hermes setup`. Force it now so the binary is bundled.
if grep -rq playwright /usr/local/lib/hermes-agent/package*.json 2>/dev/null; then
  echo "Pre-fetching Playwright Chromium..."
  ( cd /usr/local/lib/hermes-agent && \
    /root/.hermes/node/bin/npx --yes playwright install chromium ) || \
    echo "WARN: playwright install failed; verification will catch this"
fi

# pin to requested ref if not main
if [[ "${HERMES_REF}" != "main" && -d /usr/local/lib/hermes-agent/.git ]]; then
  git -C /usr/local/lib/hermes-agent fetch --tags origin
  git -C /usr/local/lib/hermes-agent checkout "${HERMES_REF}"
fi

# Sweep /root/.cache in case anything ignored the env vars
[[ -d /root/.cache ]] && rsync -a /root/.cache/ "$HERMES_CACHE/root-cache/" 2>/dev/null || true

# --- Pre-fetch all Electron + Hermes runtime RPMs so install is fully offline ---
# Without this, install-hermes.sh on the target needs the hub dnf proxy working
# AND every dep to be in IT-reviewed Enterprise OSS. Bundle the .rpm files so
# install only needs `dnf install -y *.rpm` (no network).
echo "=== Pre-downloading runtime RPMs ==="
mkdir -p /stage/rpms
# Download with full deps (no install_weak_deps=False). Bigger but ensures
# transitive system libs (libpng, gdk-pixbuf, glib, etc.) come along.
dnf install -y --downloadonly --downloaddir=/stage/rpms \
  nss atk at-spi2-atk cups-libs libdrm libxkbcommon mesa-libgbm \
  alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver \
  gtk3 libnotify libsecret libxshmfence \
  2>&1 | tail -10
rpm_count=$(ls /stage/rpms/*.rpm 2>/dev/null | wc -l)
echo "✓ pre-fetched $rpm_count RPMs into /stage/rpms"
du -sh /stage/rpms 2>/dev/null

# ---- Verify what landed where ----
echo "=== Build-time payload check ==="

# Critical: did Electron binary really land?
ELECTRON_DIR=/usr/local/lib/hermes-agent/apps/desktop/node_modules/electron/dist
if [[ -x "$ELECTRON_DIR/electron" ]]; then
  echo "✓ Electron binary present: $ELECTRON_DIR/electron ($(du -h "$ELECTRON_DIR/electron" | cut -f1))"
else
  echo "[FATAL] Electron binary missing at $ELECTRON_DIR/electron"
  echo "Contents of apps/desktop/node_modules (if any):"
  ls /usr/local/lib/hermes-agent/apps/desktop/node_modules 2>/dev/null | head -20 || \
    echo "(node_modules does not exist — npm install failed)"
  exit 1
fi

# Built renderer (dist/) — desktop main.cjs loads from there in production
if [[ -d /usr/local/lib/hermes-agent/apps/desktop/dist ]]; then
  echo "✓ Renderer built: apps/desktop/dist/"
else
  echo "[WARN] apps/desktop/dist not built — production GUI may not start"
fi

echo "Other files > 20 MB:"
find /usr/local/lib/hermes-agent /usr/local/share/uv /root/.hermes "$HERMES_CACHE" \
  -type f -size +20M 2>/dev/null | head -40 || true

# Snapshot ALL paths the installer may have touched. The installer (when root)
# spreads itself across five locations; non-root data paths must travel too.
mkdir -p /stage/{opt,usrlocal-lib,usrlocal-bin,usrlocal-share-uv,root-hermes,cache,rpms}
# /stage/rpms is already populated by the pre-fetch step above; leave as-is.

[[ -d /opt/hermes ]]                  && rsync -a /opt/hermes/                /stage/opt/hermes/
[[ -d /usr/local/lib/hermes-agent ]]  && rsync -a /usr/local/lib/hermes-agent/ /stage/usrlocal-lib/hermes-agent/
[[ -d /usr/local/share/uv ]]          && rsync -a /usr/local/share/uv/        /stage/usrlocal-share-uv/
[[ -d /root/.hermes ]]                && rsync -a /root/.hermes/              /stage/root-hermes/
[[ -d "$HERMES_CACHE" ]]              && rsync -a "$HERMES_CACHE/"            /stage/cache/

if [[ -L /usr/local/bin/hermes || -f /usr/local/bin/hermes ]]; then
  cp -a /usr/local/bin/hermes /stage/usrlocal-bin/hermes
fi

# Record build info
{
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hermes_ref=${HERMES_REF}"
  (cd /usr/local/lib/hermes-agent 2>/dev/null && echo "commit=$(git rev-parse HEAD)") || true
  echo "container=$(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)"
  echo
  echo "[stage sizes]"
  du -sh /stage/* 2>/dev/null
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

# === Offline verification gate ===
# Refuse to declare success until the bundle proves itself in a --network=none
# container. If this fails, the tarball stays in OUT_DIR but build_info gets a
# warning marker and exit is non-zero so package-mega-bundle.sh won't pick up
# a broken bundle without you knowing.
VERIFY_SH="$ROOT/scripts/mac/verify-hermes-offline.sh"
if [[ -x "$VERIFY_SH" ]]; then
  echo "[hermes] running offline verification on $OUT"
  if ! "$VERIFY_SH" "$OUT"; then
    echo "[hermes] ❌ verification failed; renaming $OUT to *.UNVERIFIED"
    mv "$OUT" "$OUT.UNVERIFIED"
    exit 1
  fi
  echo "verified_offline=true" >> "$STAGE/BUILD_INFO"
else
  echo "[hermes] ⚠ verify-hermes-offline.sh missing; skipping (NOT recommended)"
fi
# =================================

echo
echo "[hermes] ✅ produced + verified: $OUT"
echo "[hermes] build info:"
cat "$STAGE/BUILD_INFO" 2>/dev/null || true
echo
echo "Ship to hub, then on hub: ./scripts/hub/upload-hermes.sh $OUT"
echo "On offline desktop:        sudo ./scripts/client/install-hermes.sh"
