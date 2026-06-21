#!/usr/bin/env bash
# scripts/client/install-uv.sh
# Install uv on an offline RHEL 8.10 machine (sudo).
# - Drops uv + uvx binaries into /usr/local/bin/
# - Writes /etc/profile.d/uv.sh forcing system Python and disabling downloads,
#   so MCP servers / sample code that call `uv run` / `uvx` Just Work via the
#   hub-mirrored PyPI (uv reads /etc/pip.conf for the index URL automatically).
set -euo pipefail

# ============ tweak if needed ============
HUB_BASE="${HUB_BASE:-http://hub.internal:8081}"
BUNDLE_URL="${BUNDLE_URL:-$HUB_BASE/repository/raw-bundles/uv/latest.tar.gz}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
# =========================================

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

# Ensure system Python 3.12 is present (uv will use it)
command -v python3.12 >/dev/null || dnf install -y python3.12

TMP="$(mktemp -d)"; trap "rm -rf $TMP" EXIT
echo "[uv] fetching $BUNDLE_URL"
curl -fsSL "$BUNDLE_URL" -o "$TMP/uv.tar.gz"
mkdir -p "$TMP/x"
tar -C "$TMP/x" -xzf "$TMP/uv.tar.gz"

# Extract uv binary from the inner tarball
( cd "$TMP/x/uv" && tar -xzf uv.tar.gz )
UV_BIN=$(find "$TMP/x/uv" -maxdepth 3 -type f -name uv -perm -u+x | head -1)
UVX_BIN=$(find "$TMP/x/uv" -maxdepth 3 -type f -name uvx -perm -u+x | head -1)
[[ -x "$UV_BIN" ]] || { echo "[uv] uv binary not found"; exit 1; }

install -m 0755 "$UV_BIN" "$INSTALL_DIR/uv"
[[ -x "$UVX_BIN" ]] && install -m 0755 "$UVX_BIN" "$INSTALL_DIR/uvx" || true

# Lock uv to system Python + offline-safe defaults
cat > /etc/profile.d/uv.sh <<'EOF'
# uv: use system Python (dnf-installed), never reach the internet for one.
export UV_PYTHON_PREFERENCE=only-system
export UV_PYTHON_DOWNLOADS=never
# uv reads /etc/pip.conf, but be explicit (overrides any user-level pyproject).
export UV_INDEX_URL="${UV_INDEX_URL:-$(awk -F'= *' '/^index-url/ {print $2; exit}' /etc/pip.conf 2>/dev/null)}"
EOF
chmod 644 /etc/profile.d/uv.sh

# Smoke test
# shellcheck disable=SC1091
source /etc/profile.d/uv.sh
echo "[uv] version: $("$INSTALL_DIR/uv" --version 2>&1 || true)"
echo "[uv] python that uv will use:"
"$INSTALL_DIR/uv" python find 2>&1 || true
echo
cat "$TMP/x/BUILD_INFO" 2>/dev/null || true
echo
echo "[uv] ✅ installed to $INSTALL_DIR/{uv,uvx}"
echo "Try in a new shell:  uv run python -c 'import sys; print(sys.executable)'"
echo "Should print /usr/bin/python3.12 (or wherever system 3.12 lives)."
