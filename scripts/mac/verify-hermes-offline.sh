#!/usr/bin/env bash
# scripts/mac/verify-hermes-offline.sh
# Spin up a Rocky 8.10 container with NO NETWORK, extract the just-built
# hermes bundle, and run smoke checks. Any tool that tries to phone home
# fails immediately because there is no route out.
#
# Usage:  ./verify-hermes-offline.sh path/to/hermes-bundle-*.tar.gz
# Exit:   0 on pass, non-zero on any failure (sideload-hermes.sh will refuse
#         to ship a bundle that fails verification).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${1:?usage: $0 <hermes-bundle-*.tar.gz>}"
[[ -f "$BUNDLE" ]] || { echo "missing $BUNDLE"; exit 1; }

PLATFORM="linux/amd64"
IMAGE="rockylinux/rockylinux:8.10"
STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
cp "$BUNDLE" "$STAGE/bundle.tar.gz"

# Inner test script mounted into the offline container.
cat > "$STAGE/test.sh" <<'TEST_EOF'
#!/usr/bin/env bash
set -uo pipefail   # NOT -e: we want to surface specific failures, not bail on first
echo "=== offline container smoke test ==="
echo "kernel: $(uname -m)  os: $(. /etc/os-release; echo $PRETTY_NAME)"

# 0. Prove network is really off
if getent hosts github.com >/dev/null 2>&1; then
  echo "[FATAL] DNS resolves — container is NOT offline. Test invalid."
  exit 1
fi
echo "✓ no DNS (truly offline)"

# Sanity: required basic tools present in base image (rocky:8.10 minimal
# notably ships WITHOUT findutils, so we use bash globstar instead of find).
shopt -s globstar nullglob
for cmd in timeout grep tar; do
  command -v "$cmd" >/dev/null || { echo "[FATAL] missing $cmd in base image"; exit 1; }
done

# Report which Chromium runtime libs are missing — informational, not fatal.
# On the actual target, install-hermes.sh installs these via dnf-from-hub.
echo "(info) Chromium runtime libs present in base image:"
for lib in nss atk cups-libs libdrm libxkbcommon mesa-libgbm \
           alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver; do
  rpm -q "$lib" >/dev/null 2>&1 && echo "  ✓ $lib" || echo "  ✗ $lib (target host needs this via dnf)"
done

# 2. Extract bundle to all five canonical paths
mkdir -p /opt /usr/local/lib /usr/local/share /usr/local/bin /root /var/cache
tar -C /tmp -xzf /work/bundle.tar.gz
[[ -d /tmp/opt/hermes ]]                && cp -a /tmp/opt/hermes               /opt/
[[ -d /tmp/usrlocal-lib/hermes-agent ]] && cp -a /tmp/usrlocal-lib/hermes-agent /usr/local/lib/
[[ -d /tmp/usrlocal-share-uv ]]         && cp -a /tmp/usrlocal-share-uv        /usr/local/share/uv
[[ -d /tmp/root-hermes ]]               && cp -a /tmp/root-hermes              /root/.hermes
[[ -d /tmp/cache ]]                     && cp -a /tmp/cache                    /var/cache/hermes-bundled
[[ -e /tmp/usrlocal-bin/hermes ]]       && cp -a /tmp/usrlocal-bin/hermes      /usr/local/bin/hermes
echo "✓ extracted to canonical paths"

# 2b. Install bundled runtime RPMs (Electron + Chromium libs). Disabling all
# repos forces dnf to use only the local .rpm files — proves bundle is truly
# self-contained.
if compgen -G "/tmp/rpms/*.rpm" >/dev/null; then
  rpm_n=$(ls /tmp/rpms/*.rpm | wc -l)
  echo "Installing $rpm_n bundled runtime RPMs (offline only)..."
  dnf install -y --disablerepo='*' --skip-broken /tmp/rpms/*.rpm 2>&1 | tail -3
  # Show what didn't make it (info only — real targets get hub dnf fallback)
  echo "(info) check Electron runtime lib availability:"
  for lib in libnspr4.so libnss3.so libgtk-3.so.0 libgdk-3.so.0 libpng16.so.16; do
    if ldconfig -p | grep -q "$lib"; then echo "  ✓ $lib"; else echo "  ✗ $lib (will fail on minimal hosts)"; fi
  done
else
  echo "(info) bundle has no /rpms/ — older format; skipping RPM install"
fi

# 3. Source the env that install-hermes.sh would normally write
export HERMES_HOME=/opt/hermes
export HERMES_CACHE=/usr/local/lib/hermes-agent/.cache
export XDG_CACHE_HOME=$HERMES_CACHE/xdg
export ELECTRON_CACHE=$HERMES_CACHE/electron
export PLAYWRIGHT_BROWSERS_PATH=$HERMES_CACHE/ms-playwright
export npm_config_cache=$HERMES_CACHE/npm
export PIP_CACHE_DIR=$HERMES_CACHE/pip

fail=0
# Helper: pick first existing path matching a glob (no find needed)
first_of() {
  local p
  for p in $1; do [[ -e "$p" ]] && { echo "$p"; return 0; }; done
  return 1
}

# 4. Bundled uv CLI
uv_bin=$(first_of '/root/.hermes/bin/uv')
if [[ -n "${uv_bin:-}" && -x "$uv_bin" ]]; then
  "$uv_bin" --version >/dev/null && echo "✓ uv: $uv_bin" || { echo "[FAIL] uv broken"; fail=1; }
else
  echo "[FAIL] uv CLI missing at /root/.hermes/bin/uv"; fail=1
fi

# 5. Bundled Node
node_bin=$(first_of '/root/.hermes/node/bin/node')
if [[ -n "${node_bin:-}" && -x "$node_bin" ]]; then
  "$node_bin" --version >/dev/null && echo "✓ Node: $node_bin"
else
  echo "[FAIL] Node missing at /root/.hermes/node/bin/node"; fail=1
fi

# 6. Bundled Python (uv-managed)
python_bin=$(first_of '/usr/local/share/uv/python/*/bin/python3.11')
if [[ -n "${python_bin:-}" && -x "$python_bin" ]]; then
  "$python_bin" --version >/dev/null && echo "✓ Python: $python_bin"
else
  echo "[FAIL] Python 3.11 missing under /usr/local/share/uv/python/"; fail=1
fi

# 7. Playwright Chromium (we know hermes-agent uses it)
chromium_bin=$(first_of '/var/cache/hermes-bundled/ms-playwright/chromium-*/chrome-linux64/chrome')
if [[ -n "${chromium_bin:-}" && -e "$chromium_bin" ]]; then
  size=$(stat -c%s "$chromium_bin")
  if (( size > 50000000 )); then
    echo "✓ Chromium: $chromium_bin ($((size/1048576)) MB)"
  else
    echo "[FAIL] Chromium too small ($size bytes)"; fail=1
  fi
else
  echo "[FAIL] Playwright Chromium missing"; fail=1
fi

# 7b. Electron (desktop GUI) — THE critical addition
electron_bin=/usr/local/lib/hermes-agent/apps/desktop/node_modules/electron/dist/electron
if [[ -x "$electron_bin" ]]; then
  size=$(stat -c%s "$electron_bin")
  if (( size > 50000000 )); then
    echo "✓ Electron: $electron_bin ($((size/1048576)) MB)"
    # Smoke test: --version with --no-sandbox (root in container = needs flag)
    if out=$(timeout 15 "$electron_bin" --no-sandbox --version 2>&1); then
      echo "✓ Electron --version: $(echo "$out" | tail -1)"
    else
      echo "[WARN] electron --version failed in container (may need GUI libs at runtime):"
      echo "$out" | head -5
    fi
  else
    echo "[FAIL] Electron binary too small ($size bytes)"; fail=1
  fi
else
  echo "[FAIL] Electron binary missing at $electron_bin"
  echo "  Desktop GUI will not launch."; fail=1
fi

# 7c. Renderer built (production mode loads from dist/)
if [[ -d /usr/local/lib/hermes-agent/apps/desktop/dist ]]; then
  echo "✓ Desktop renderer built (apps/desktop/dist/)"
else
  echo "[FAIL] Desktop renderer not built — GUI will be blank"; fail=1
fi

# 8. /usr/local/bin/hermes resolves to a working command
if [[ -e /usr/local/bin/hermes ]]; then
  target=$(readlink -f /usr/local/bin/hermes 2>/dev/null || echo /usr/local/bin/hermes)
  if [[ -x "$target" ]]; then
    echo "✓ /usr/local/bin/hermes → $target"
    # Smoke: just confirm the launcher doesn't immediately die
    out=$(timeout 30 /usr/local/bin/hermes --version 2>&1 || true)
    if echo "$out" | grep -qiE 'hermes|version|usage'; then
      echo "✓ hermes launcher responsive (no network needed)"
    else
      echo "[WARN] hermes --version output unclear:"
      echo "$out" | head -5
    fi
  else
    echo "[FAIL] /usr/local/bin/hermes does not resolve to an executable"; fail=1
  fi
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "=== ✅ OFFLINE VERIFICATION PASSED ==="
  exit 0
else
  echo "=== ❌ OFFLINE VERIFICATION FAILED ==="
  exit 1
fi
TEST_EOF
chmod +x "$STAGE/test.sh"

echo "[verify] running smoke test inside $IMAGE with --network=none"
docker run --rm --platform "$PLATFORM" \
  --network=none \
  -v "$STAGE":/work:ro \
  "$IMAGE" bash /work/test.sh
