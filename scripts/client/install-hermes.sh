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

# 1. minimum tools needed by this script itself (git curl tar xz rsync are
# almost always already present on RHEL 8.10; skip prompt for these).
for t in git curl tar xz rsync; do
  command -v "$t" >/dev/null || { echo "[hermes] missing $t — needed for this script"; \
    dnf install -y "$t" || { echo "[FATAL] cannot install $t"; exit 1; }; }
done

# 2. fetch bundle
TMP="$(mktemp -d)"; trap "rm -rf $TMP" EXIT

# If first arg is a local .tar.gz path, use it directly (helper flow).
# Otherwise fetch from hub (default flow). --install-deps is consumed earlier.
LOCAL_BUNDLE=""
for arg in "$@"; do
  [[ "$arg" == "--install-deps" ]] && continue
  if [[ -f "$arg" && "$arg" == *.tar.gz ]]; then
    LOCAL_BUNDLE="$arg"
    break
  fi
done

if [[ -n "$LOCAL_BUNDLE" ]]; then
  echo "[hermes] using local bundle: $LOCAL_BUNDLE"
  cp "$LOCAL_BUNDLE" "$TMP/hermes.tar.gz"
else
  echo "[hermes] fetching $BUNDLE_URL"
  curl -fsSL "$BUNDLE_URL" -o "$TMP/hermes.tar.gz"
fi

mkdir -p "$TMP/extract"
tar -C "$TMP/extract" -xzf "$TMP/hermes.tar.gz"

# 2b. Install bundled RPMs (Electron + Chromium runtime libs) — no network
# needed. Falls back to dnf-via-hub if RPMs are missing (older bundle).
# 2c. Inspect what runtime RPMs are needed vs already installed.
# Default: DRY RUN — list missing, do NOT install. The user re-runs with
# HERMES_INSTALL_DEPS=yes (or --install-deps) to actually install.
HERMES_INSTALL_DEPS="${HERMES_INSTALL_DEPS:-}"
for arg in "$@"; do [[ "$arg" == "--install-deps" ]] && HERMES_INSTALL_DEPS=yes; done

if compgen -G "$TMP/extract/rpms/*.rpm" >/dev/null; then
  echo
  echo "[hermes] inspecting bundled runtime RPMs vs what's already on this host"
  declare -a missing_rpms=()
  declare -a missing_names=()
  declare -a already=()
  for rpm in "$TMP/extract/rpms"/*.rpm; do
    name=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null) || continue
    if rpm -q "$name" >/dev/null 2>&1; then
      already+=("$name")
    else
      missing_rpms+=("$rpm")
      missing_names+=("$name")
    fi
  done
  echo "  already installed: ${#already[@]} package(s)"
  echo "  missing on host:   ${#missing_rpms[@]} package(s)"
  if [[ ${#missing_rpms[@]} -gt 0 ]]; then
    echo
    echo "  Packages that need installing for Hermes desktop to launch:"
    printf "    - %s\n" "${missing_names[@]}"
    echo
    if [[ "$HERMES_INSTALL_DEPS" == "yes" ]]; then
      echo "[hermes] HERMES_INSTALL_DEPS=yes → installing the missing ones (offline, from bundle)"
      dnf install -y --disablerepo='*' "${missing_rpms[@]}" 2>&1 | tail -10
    else
      echo "  >>> Default: will NOT auto-install. To install just these missing ones, re-run with:"
      echo "  >>>     sudo HERMES_INSTALL_DEPS=yes $0"
      echo "  >>> Or:    sudo $0 --install-deps"
      echo "  >>> (Hermes files will still be extracted now; Electron may not launch until you install the above.)"
      INSTALL_DEPS_SKIPPED=1
    fi
  else
    echo "  ✓ all Electron runtime deps satisfied; nothing to install"
  fi
fi

# 3. back up existing install if present. The installer spreads itself across
# five paths (FHS code + per-user data); restore all of them.
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
for p in "$HERMES_HOME" /usr/local/lib/hermes-agent /usr/local/share/uv \
         /root/.hermes /var/cache/hermes-bundled /usr/local/bin/hermes; do
  backup "$p"
done

# 4. restore. Paths are path-stable (installer bakes absolute paths in
# venv shebangs and uv shim configs). Do not change them.
echo "[hermes] installing to canonical paths"
mkdir -p "$HERMES_HOME" "$HERMES_LIB" /usr/local/share /root /var/cache /usr/local/bin

[[ -d "$TMP/extract/opt/hermes" ]]                && rsync -a "$TMP/extract/opt/hermes/"                "$HERMES_HOME/"
[[ -d "$TMP/extract/usrlocal-lib/hermes-agent" ]] && rsync -a "$TMP/extract/usrlocal-lib/hermes-agent/" "$HERMES_LIB/"
[[ -d "$TMP/extract/usrlocal-share-uv" ]]         && rsync -a "$TMP/extract/usrlocal-share-uv/"         /usr/local/share/uv/
[[ -d "$TMP/extract/root-hermes" ]]               && rsync -a "$TMP/extract/root-hermes/"               /root/.hermes/
[[ -d "$TMP/extract/cache" ]]                     && rsync -a "$TMP/extract/cache/"                     /var/cache/hermes-bundled/

# Custom HERMES_LIB → expose canonical path via symlink for shebangs
if [[ "$HERMES_LIB" != "/usr/local/lib/hermes-agent" ]]; then
  mkdir -p /usr/local/lib
  ln -sf "$HERMES_LIB" /usr/local/lib/hermes-agent
fi

if [[ -e "$TMP/extract/usrlocal-bin/hermes" ]]; then
  cp -a "$TMP/extract/usrlocal-bin/hermes" /usr/local/bin/hermes
fi

# Desktop GUI launcher. The upstream installer only creates the CLI launcher;
# `hermes-desktop` lets users open the Electron window. Requires an X11 /
# Wayland session (run from a graphical login, not bare SSH).
cat > /usr/local/bin/hermes-desktop <<'EOF'
#!/usr/bin/env bash
# Launch the Hermes Electron desktop app.
set -euo pipefail
DESKTOP_DIR=/usr/local/lib/hermes-agent/apps/desktop
ELECTRON_BIN="$DESKTOP_DIR/node_modules/electron/dist/electron"
if [[ ! -x "$ELECTRON_BIN" ]]; then
  echo "hermes-desktop: Electron binary missing at $ELECTRON_BIN" >&2
  exit 1
fi
cd "$DESKTOP_DIR"
# --no-sandbox needed on systems where chrome-sandbox SUID isn't configured
# (offline RHEL with rootless container build). Safe inside a corporate LAN.
exec "$ELECTRON_BIN" --no-sandbox . "$@"
EOF
chmod +x /usr/local/bin/hermes-desktop

# Multi-user fix: upstream root-mode installer hardcodes Node + uv into
# /root/.hermes/{node,bin} (mode 700). Non-root users can't reach them.
# Relocate to /opt/hermes-tools (world-readable), symlink back so root keeps
# working, and export PATH for all users.
if [[ -d /root/.hermes/node || -d /root/.hermes/bin ]]; then
  echo "[hermes] relocating shared tools to /opt/hermes-tools/ for multi-user"
  mkdir -p /opt/hermes-tools
  for sub in node bin; do
    if [[ -d /root/.hermes/$sub && ! -L /root/.hermes/$sub ]]; then
      rm -rf "/opt/hermes-tools/$sub"
      mv "/root/.hermes/$sub" "/opt/hermes-tools/$sub"
      ln -s "/opt/hermes-tools/$sub" "/root/.hermes/$sub"
    fi
  done
  chmod -R a+rX /opt/hermes-tools
fi

# 4b. persist HERMES_HOME + redirect all cache dirs to bundled-tree locations
# so Electron / Playwright / npm / pip find their pre-downloaded binaries
# and never reach for the internet on first run.
cat > /etc/profile.d/hermes.sh <<EOF
export HERMES_HOME=$HERMES_HOME
# Point every common cache env var at the bundled snapshot. The build script
# wrote binaries here; runtime must look here too.
export HERMES_CACHE=$HERMES_LIB/.cache
export XDG_CACHE_HOME=\$HERMES_CACHE/xdg
export ELECTRON_CACHE=\$HERMES_CACHE/electron
export PLAYWRIGHT_BROWSERS_PATH=\$HERMES_CACHE/ms-playwright
export npm_config_cache=\$HERMES_CACHE/npm
export PIP_CACHE_DIR=\$HERMES_CACHE/pip
# Hermes-managed Node/uv tools, system-wide
if [ -d /opt/hermes-tools/node/bin ]; then
  export PATH=/opt/hermes-tools/node/bin:\$PATH
fi
if [ -d /opt/hermes-tools/bin ]; then
  export PATH=/opt/hermes-tools/bin:\$PATH
fi
EOF
chmod 644 /etc/profile.d/hermes.sh

# 5. final reminder about deps that weren't installed
if [[ "${INSTALL_DEPS_SKIPPED:-}" == "1" ]]; then
  echo
  echo "============================================================"
  echo "  REMINDER: ${#missing_rpms[@]} Electron runtime package(s) were"
  echo "  detected as MISSING but NOT installed (dry-run mode)."
  echo "  hermes-desktop will fail to launch until you run:"
  echo "      sudo HERMES_INSTALL_DEPS=yes $0"
  echo "  (Or you may install them yourself from /opt/hermes-tools or dnf.)"
  echo "============================================================"
fi

# 6. smoke test
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
