#!/usr/bin/env bash
# scripts/client/install-hermes.sh
# Run on offline RHEL 8.10 desktop (sudo). Pulls latest hermes bundle from
# the hub's raw-bundles and restores the three install paths:
#   /opt/hermes  +  /usr/local/lib/hermes-agent  +  /usr/local/bin/hermes
set -euo pipefail

# ============ fill in ============
HUB_BASE="${HUB_BASE:-http://hub.internal:8081}"
BUNDLE_URL="${BUNDLE_URL:-$HUB_BASE/repository/raw-bundles/hermes/latest.tar.gz}"

# Where to put Hermes user data + config. Safe to change anytime; just rerun
# this script or move the directory and update /etc/profile.d/hermes.sh.
# Empty = use installer default (/opt/hermes).
HERMES_HOME="${HERMES_HOME:-/opt/hermes}"

# Where to put Hermes code (venv + node_modules). Path is baked into venv
# shebangs at build time, so changing this requires a symlink at the original
# /usr/local/lib/hermes-agent path. The script handles that for you.
HERMES_LIB="${HERMES_LIB:-/usr/local/lib/hermes-agent}"
# =================================

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

# 1. system deps (routed through hub dnf proxies via bootstrap-client.sh)
echo "[hermes] dnf install system libraries"
dnf install -y --setopt=install_weak_deps=False \
  git curl tar xz rsync \
  nss atk at-spi2-atk cups-libs libdrm libxkbcommon mesa-libgbm \
  alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver
# ripgrep + ffmpeg are optional speedups
dnf install -y ripgrep ffmpeg-free 2>/dev/null || true

# 2. fetch bundle
TMP="$(mktemp -d)"; trap "rm -rf $TMP" EXIT
echo "[hermes] fetching $BUNDLE_URL"
curl -fsSL "$BUNDLE_URL" -o "$TMP/hermes.tar.gz"
mkdir -p "$TMP/extract"
tar -C "$TMP/extract" -xzf "$TMP/hermes.tar.gz"

# 3. back up existing install if present (resolving symlinks for HERMES_LIB)
TS="$(date -u +%Y%m%d-%H%M%S)"
backup() {
  local p="$1"
  if [[ -L "$p" ]]; then
    local tgt; tgt="$(readlink -f "$p")"
    echo "[hermes] $p is a symlink → $tgt; backing up target"
    [[ -e "$tgt" ]] && mv "$tgt" "$tgt.bak.$TS"
    rm "$p"
  elif [[ -e "$p" ]]; then
    echo "[hermes] backing up $p → $p.bak.$TS"
    mv "$p" "$p.bak.$TS"
  fi
}
backup "$HERMES_HOME"
backup /usr/local/lib/hermes-agent
backup /usr/local/bin/hermes

# 4. restore
echo "[hermes] installing"
echo "  HERMES_HOME=$HERMES_HOME"
echo "  HERMES_LIB =$HERMES_LIB  (symlinked from /usr/local/lib/hermes-agent if different)"
mkdir -p "$HERMES_HOME" "$HERMES_LIB" /usr/local/bin
[[ -d "$TMP/extract/opt/hermes" ]] && rsync -a "$TMP/extract/opt/hermes/" "$HERMES_HOME/"
[[ -d "$TMP/extract/usrlocal-lib/hermes-agent" ]] && rsync -a "$TMP/extract/usrlocal-lib/hermes-agent/" "$HERMES_LIB/"

# If user customized HERMES_LIB, expose it at the canonical path via symlink
# so the venv shebangs (which are baked at build time pointing at
# /usr/local/lib/hermes-agent/.venv/...) still resolve.
if [[ "$HERMES_LIB" != "/usr/local/lib/hermes-agent" ]]; then
  mkdir -p /usr/local/lib
  ln -sf "$HERMES_LIB" /usr/local/lib/hermes-agent
fi

if [[ -e "$TMP/extract/usrlocal-bin/hermes" ]]; then
  cp -a "$TMP/extract/usrlocal-bin/hermes" /usr/local/bin/hermes
fi

# 4b. persist HERMES_HOME so users don't need to export it every shell
cat > /etc/profile.d/hermes.sh <<EOF
export HERMES_HOME=$HERMES_HOME
EOF
chmod 644 /etc/profile.d/hermes.sh

# 5. smoke test
if [[ -x /usr/local/bin/hermes ]]; then
  echo "[hermes] ✅ installed. Build info:"
  cat "$TMP/extract/BUILD_INFO" 2>/dev/null || true
  echo
  echo "Try:  hermes --help"
  echo "First-run setup (if needed):  hermes setup"
else
  echo "[hermes] ⚠ /usr/local/bin/hermes missing — check bundle contents:"
  ls "$TMP/extract"
  exit 1
fi
