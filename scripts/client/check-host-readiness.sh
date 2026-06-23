#!/usr/bin/env bash
# scripts/client/check-host-readiness.sh
# Pre-flight check: does this RHEL 8.10 host have the baseline desktop /
# system libs that Hermes bundle assumes? Run BEFORE install-hermes.sh to
# avoid surprise dnf failures.
#
# Exit 0 = ready. Exit 1 = something critical missing. Exit 2 = warnings only.
# Does NOT require root; doesn't install anything; doesn't touch the system.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CLR='\033[0m'
ok=0; warn=0; fail=0
say_ok()   { printf "${GREEN}✓${CLR} %s\n" "$1"; ok=$((ok+1)); }
say_warn() { printf "${YELLOW}⚠${CLR} %s\n" "$1"; warn=$((warn+1)); }
say_fail() { printf "${RED}✗${CLR} %s\n" "$1"; fail=$((fail+1)); }

echo "=== Hermes bundle readiness check ==="
echo "host:   $(hostname)"
echo "uname:  $(uname -mrs)"
[[ -f /etc/os-release ]] && echo "os:     $(. /etc/os-release; echo "$PRETTY_NAME")"
echo

# 1. OS family
if [[ -f /etc/os-release ]] && grep -qE 'ID_LIKE=.*rhel|ID="?(rhel|rocky|almalinux|centos)"?' /etc/os-release; then
  ver=$(. /etc/os-release; echo "$VERSION_ID")
  if [[ "$ver" =~ ^8\. ]]; then
    say_ok "OS is RHEL-family 8.x ($ver) — matches bundle target"
  else
    say_fail "OS is RHEL-family but version $ver, bundle is for 8.10"
  fi
else
  say_fail "OS is not RHEL/Rocky/Alma/CentOS 8 — bundle will not work"
fi

# 2. Architecture
[[ "$(uname -m)" == "x86_64" ]] && say_ok "arch x86_64" || say_fail "arch $(uname -m) — bundle is x86_64 only"

# 3. Basic tools install-hermes.sh needs
for t in tar xz curl rsync rpm dnf; do
  command -v "$t" >/dev/null && say_ok "$t present" || say_fail "$t missing (install-hermes.sh needs it)"
done

# 4. GUI session libraries Hermes Electron needs at runtime.
# These come either from the bundled 35 RPMs OR from a standard RHEL 8.10
# desktop install. Missing here just means HERMES_INSTALL_DEPS=yes will
# install them from the bundle — not fatal.
echo
echo "--- Electron runtime libraries ---"
for pkg in nss atk at-spi2-atk cups-libs libdrm libxkbcommon mesa-libgbm \
           alsa-lib pango libXcomposite libXdamage libXrandr libXScrnSaver \
           gtk3 libnotify libsecret libxshmfence; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    say_ok "$pkg installed"
  else
    say_warn "$pkg missing (will be installed from bundle if you pass HERMES_INSTALL_DEPS=yes)"
  fi
done

# 5. Base system libs the bundled RPMs assume exist. These come with a
# standard desktop install of RHEL 8.10. If any are missing, the host is
# unusually minimal and HERMES_INSTALL_DEPS=yes may need hub dnf fallback.
echo
echo "--- Base system libraries (expected on RHEL 8.10 desktop) ---"
for so in libpng16.so.16 libjpeg.so.62 libglib-2.0.so.0 libdbus-1.so.3 \
          libcairo.so.2 libfreetype.so.6 libfontconfig.so.1; do
  if ldconfig -p 2>/dev/null | grep -q "$so"; then
    say_ok "$so available"
  else
    say_fail "$so missing — host is more minimal than bundle assumes; hub dnf fallback required"
  fi
done

# 6. Display environment for hermes-desktop to actually show a window
echo
echo "--- Display environment (for hermes-desktop GUI) ---"
if [[ -n "${DISPLAY:-}" ]]; then
  say_ok "DISPLAY=$DISPLAY (X11 session available; hermes-desktop can show window)"
elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  say_ok "WAYLAND_DISPLAY=$WAYLAND_DISPLAY (Wayland session)"
else
  say_warn "no DISPLAY/WAYLAND_DISPLAY — you can install but hermes-desktop won't show GUI from this shell (use VNC / X11 forward / desktop login)"
fi

# 7. Disk space — install needs ~3 GB free (1.3 GB tarball + extracted tree)
echo
echo "--- Disk space ---"
for path in /usr/local /opt /var/cache /root; do
  if [[ -d "$path" ]]; then
    avail=$(df -BM "$path" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}')
    if [[ "$avail" -ge 1500 ]]; then
      say_ok "$path: ${avail} MB free"
    elif [[ "$avail" -ge 500 ]]; then
      say_warn "$path: only ${avail} MB free (tight; OK if you split paths)"
    else
      say_fail "$path: only ${avail} MB free — need ~1.5 GB"
    fi
  fi
done

# 8. Bundle file presence (if user passed a path)
if [[ $# -gt 0 && -f "$1" ]]; then
  echo
  echo "--- Bundle file ---"
  size_mb=$(du -m "$1" | cut -f1)
  if (( size_mb >= 1000 )); then
    say_ok "bundle $1 is ${size_mb} MB (plausible)"
  else
    say_warn "bundle $1 is ${size_mb} MB (smaller than expected ~1.3 GB)"
  fi
  if [[ -f "${1%.tar.gz}.sha256" ]]; then
    if ( cd "$(dirname "$1")" && sha256sum -c "$(basename "${1%.tar.gz}.sha256")" >/dev/null 2>&1 ); then
      say_ok "sha256 matches"
    else
      say_fail "sha256 MISMATCH — bundle download is corrupt"
    fi
  fi
fi

# Summary
echo
echo "=== Summary ==="
printf "${GREEN}✓ %d ok${CLR}   ${YELLOW}⚠ %d warn${CLR}   ${RED}✗ %d fail${CLR}\n" "$ok" "$warn" "$fail"
if (( fail > 0 )); then
  echo "FAIL: host is missing something critical. Address fails before running install-hermes.sh."
  exit 1
elif (( warn > 0 )); then
  echo "Ready with warnings — run sudo HERMES_INSTALL_DEPS=yes ./install-hermes.sh to install missing pieces from the bundle."
  exit 2
else
  echo "Ready. Run sudo ./install-hermes.sh to install Hermes."
  exit 0
fi
