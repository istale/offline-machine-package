#!/usr/bin/env bash
# bootstrap-client.sh
# 每台離線機 (RHEL 8.10) 跑一次。
# 設定 dnf / pip / npm / podman 全部走中樞 Nexus。
# 需要 sudo（寫 /etc/yum.repos.d、/etc/containers）。
set -euo pipefail

# ============ 你要填 ============
HUB_HOSTNAME=""                       # 例: hub.internal
NEXUS_PORT="${NEXUS_PORT:-8081}"
DOCKER_PORT="${DOCKER_PORT:-8082}"
# ===============================

[[ -n "$HUB_HOSTNAME" ]] || { echo "❌ 請先填 HUB_HOSTNAME"; exit 1; }
HUB_BASE="http://${HUB_HOSTNAME}:${NEXUS_PORT}"
DOCKER_HOST="${HUB_HOSTNAME}:${DOCKER_PORT}"

log() { echo "[client] $*"; }

# --- 1. dnf repos ---
log "寫 /etc/yum.repos.d/internal.repo"
sudo tee /etc/yum.repos.d/internal.repo >/dev/null <<EOF
[internal-baseos]
name=Internal Rocky 8 BaseOS (via Nexus)
baseurl=${HUB_BASE}/repository/rocky-8-baseos-proxy/
enabled=1
gpgcheck=0

[internal-appstream]
name=Internal Rocky 8 AppStream (via Nexus)
baseurl=${HUB_BASE}/repository/rocky-8-appstream-proxy/
enabled=1
gpgcheck=0

[internal-epel]
name=Internal EPEL 8 (via Nexus)
baseurl=${HUB_BASE}/repository/epel-8-proxy/
enabled=1
gpgcheck=0

[internal-rpm]
name=Internal hosted RPM (sideloaded)
baseurl=${HUB_BASE}/repository/rpm-internal/
enabled=1
gpgcheck=0
EOF

# 停掉原廠 repo (避免 dnf 還想連外網)
log "禁用原廠 .repo（備份成 *.disabled）"
for f in /etc/yum.repos.d/*.repo; do
  case "$(basename "$f")" in internal.repo) ;; *) sudo mv "$f" "$f.disabled" ;; esac
done

sudo dnf clean all
sudo dnf repolist

# --- 2. pip ---
log "寫 /etc/pip.conf（所有 user 共用）"
sudo mkdir -p /etc
sudo tee /etc/pip.conf >/dev/null <<EOF
[global]
index-url = ${HUB_BASE}/repository/pypi-group/simple/
trusted-host = ${HUB_HOSTNAME}
timeout = 60
EOF

# --- 3. npm ---
log "寫 /etc/npmrc（所有 user 共用）"
sudo tee /etc/npmrc >/dev/null <<EOF
registry=${HUB_BASE}/repository/npm-group/
strict-ssl=false
EOF

# --- 4. podman / 容器 registry ---
log "寫 /etc/containers/registries.conf.d/internal.conf"
sudo mkdir -p /etc/containers/registries.conf.d
sudo tee /etc/containers/registries.conf.d/internal.conf >/dev/null <<EOF
unqualified-search-registries = ["${DOCKER_HOST}"]

[[registry]]
location = "${DOCKER_HOST}"
insecure = true
EOF

# --- 5. 驗證 ---
log "驗證 dnf"
sudo dnf repolist enabled
log "驗證 pip"
pip3 config list 2>/dev/null || python3 -m pip config list 2>/dev/null || true
log "驗證 podman"
podman info | grep -A2 -i 'registries\|insecure' || true

cat <<EOF

============================================================
✅ Client 設定完成
   pip install <pkg>        → 走 ${HUB_BASE}/repository/pypi-group/
   npm install <pkg>        → 走 ${HUB_BASE}/repository/npm-group/
   dnf install <pkg>        → 走 ${HUB_BASE}/repository/*-proxy/
   podman pull <image>      → 走 ${DOCKER_HOST}

若某套件 OSS 沒有 (IT 嚴審名單外)：
   1. Mac 端用 howto 流程下載
   2. 上傳到中樞 pypi-internal / npm-internal / rpm-internal / docker-hosted
   3. 重新 install 即可（group 會優先看 internal）
============================================================
EOF
