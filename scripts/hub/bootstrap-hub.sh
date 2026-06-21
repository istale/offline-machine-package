#!/usr/bin/env bash
# bootstrap-hub.sh
# 中樞機 (RHEL 8.10) 以 webadmin 身分跑。
# 前置：已執行 load-images.sh，podman images 看得到 sonatype/nexus3。
#
# 做的事：
#   1. 建 NetApp 上的 nexus-data 目錄、權限
#   2. 用 rootless podman 起 Nexus，寫成 systemd --user unit (lingering)
#   3. 等 Nexus ready，撈初始 admin 密碼
#   4. REST API 自動建好所有 repo (proxy + hosted + group)
#   5. 印出 client 端要用的設定值
#
# 失敗安全：每個 REST 呼叫都檢查 HTTP code；已存在的 repo 會 skip。
set -euo pipefail

# ============ 你要填的變數 ============
HUB_HOSTNAME=""                                  # 例: hub.internal
NEXUS_DATA=""                                    # 例: /srv/nexus-data  (NetApp 掛載點)

# 企業 Nexus OSS 上游（IT 嚴審，沒有的套件靠 *-internal 補）
ENTERPRISE_OSS_BASE=""                           # 例: http://oss.corp:8081
ENTERPRISE_PYPI_URL=""                           # 例: ${ENTERPRISE_OSS_BASE}/repository/pypi/  （注意：不是 simple/）
ENTERPRISE_NPM_URL=""                            # 例: ${ENTERPRISE_OSS_BASE}/repository/npm/
ENTERPRISE_DNF_BASEOS_URL=""                     # 例: ${ENTERPRISE_OSS_BASE}/repository/rocky-8-baseos/
ENTERPRISE_DNF_APPSTREAM_URL=""                  # 例: ${ENTERPRISE_OSS_BASE}/repository/rocky-8-appstream/
ENTERPRISE_DNF_EPEL_URL=""                       # 例: ${ENTERPRISE_OSS_BASE}/repository/epel-8/

OSS_USER=""                                      # 沒有就留空
OSS_PASS=""                                      # 沒有就留空

NEXUS_PORT="${NEXUS_PORT:-8081}"
DOCKER_PORT="${DOCKER_PORT:-8082}"
NEXUS_IMAGE="${NEXUS_IMAGE:-docker.io/sonatype/nexus3:latest}"
# ======================================

die() { echo "❌ $*" >&2; exit 1; }
log() { echo "[hub] $*"; }

[[ -n "$HUB_HOSTNAME" ]] || die "請先填 HUB_HOSTNAME"
[[ -n "$NEXUS_DATA"   ]] || die "請先填 NEXUS_DATA"
[[ "$(id -un)" == "webadmin" ]] || die "請用 webadmin 身分跑 (目前: $(id -un))"

# --- 1. 目錄與權限 ---
log "建立 $NEXUS_DATA"
mkdir -p "$NEXUS_DATA"
# Nexus container 內 uid 200。rootless podman 會把 container uid 200 映射到 host 一個 subuid。
# 用 podman unshare chown 才對得到正確的 host uid。
podman unshare chown -R 200:200 "$NEXUS_DATA"

# --- 2. systemd --user unit ---
log "啟用 webadmin lingering（讓 user service 開機自動跑）"
loginctl enable-linger "$(id -un)" 2>/dev/null || sudo loginctl enable-linger "$(id -un)"

mkdir -p "$HOME/.config/systemd/user"
UNIT="$HOME/.config/systemd/user/nexus.service"
log "寫 systemd unit: $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Nexus Repository Manager (rootless podman)
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
ExecStartPre=-/usr/bin/podman rm -f nexus
ExecStart=/usr/bin/podman run --name nexus --rm \\
  -p ${NEXUS_PORT}:8081 \\
  -p ${DOCKER_PORT}:${DOCKER_PORT} \\
  -v ${NEXUS_DATA}:/nexus-data:Z \\
  --memory=4g \\
  ${NEXUS_IMAGE}
ExecStop=/usr/bin/podman stop -t 30 nexus

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now nexus.service
log "Nexus 啟動中（首次冷啟動約 60–120 秒）..."

# --- 3. 等 ready ---
BASE="http://127.0.0.1:${NEXUS_PORT}"
for i in $(seq 1 60); do
  if curl -sf "$BASE/service/rest/v1/status" >/dev/null; then
    log "Nexus ready"
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && die "Nexus 等 5 分鐘還沒起來，看 podman logs nexus"
done

# 撈初始 admin 密碼（首次啟動才有）
ADMIN_PW_FILE="$NEXUS_DATA/admin.password"
if [[ -f "$ADMIN_PW_FILE" ]]; then
  ADMIN_PW="$(cat "$ADMIN_PW_FILE")"
  log "初始 admin 密碼: $ADMIN_PW （登入後請改密碼，再把這檔殺掉）"
else
  log "找不到 admin.password — 假設已改過密碼。請手動輸入："
  read -rsp "admin password: " ADMIN_PW; echo
fi

AUTH=(-u "admin:$ADMIN_PW")
API="$BASE/service/rest/v1"

# --- 4. 建 repo ---
# helper: POST JSON 建 repo；409 (已存在) 視為成功
create_repo() {
  local kind="$1" json="$2"
  local code
  code=$(curl -sS -o /tmp/nexus.out -w '%{http_code}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -X POST "$API/repositories/$kind" -d "$json")
  if [[ "$code" == "201" ]]; then echo "  ✓ created"
  elif [[ "$code" == "400" ]] && grep -q "already exists" /tmp/nexus.out; then echo "  • already exists, skip"
  else echo "  ✗ HTTP $code"; cat /tmp/nexus.out; return 1
  fi
}

# 上游 auth 區塊（若有帳密）
if [[ -n "$OSS_USER" ]]; then
  HTTP_CLIENT_AUTH=', "authentication": {"type":"username","username":"'"$OSS_USER"'","password":"'"$OSS_PASS"'"}'
else
  HTTP_CLIENT_AUTH=""
fi

log "建 PyPI proxy / hosted / group"
echo -n "  pypi-proxy:    "
create_repo pypi/proxy "$(cat <<JSON
{"name":"pypi-proxy","online":true,
 "storage":{"blobStoreName":"default","strictContentTypeValidation":true},
 "proxy":{"remoteUrl":"$ENTERPRISE_PYPI_URL","contentMaxAge":-1,"metadataMaxAge":1440},
 "negativeCache":{"enabled":true,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true$HTTP_CLIENT_AUTH}}
JSON
)"
echo -n "  pypi-internal: "
create_repo pypi/hosted '{"name":"pypi-internal","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW"}}'
echo -n "  pypi-group:    "
create_repo pypi/group '{"name":"pypi-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false},"group":{"memberNames":["pypi-internal","pypi-proxy"]}}'

log "建 npm proxy / hosted / group"
echo -n "  npm-proxy:    "
create_repo npm/proxy "$(cat <<JSON
{"name":"npm-proxy","online":true,
 "storage":{"blobStoreName":"default","strictContentTypeValidation":true},
 "proxy":{"remoteUrl":"$ENTERPRISE_NPM_URL","contentMaxAge":-1,"metadataMaxAge":1440},
 "negativeCache":{"enabled":true,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true$HTTP_CLIENT_AUTH}}
JSON
)"
echo -n "  npm-internal: "
create_repo npm/hosted '{"name":"npm-internal","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}'
echo -n "  npm-group:    "
create_repo npm/group '{"name":"npm-group","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"group":{"memberNames":["npm-internal","npm-proxy"]}}'

log "建 yum proxy × 3 + hosted + group"
mk_yum_proxy() {
  local name="$1" url="$2"
  echo -n "  $name: "
  create_repo yum/proxy "$(cat <<JSON
{"name":"$name","online":true,
 "storage":{"blobStoreName":"default","strictContentTypeValidation":true},
 "proxy":{"remoteUrl":"$url","contentMaxAge":1440,"metadataMaxAge":1440},
 "negativeCache":{"enabled":true,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true$HTTP_CLIENT_AUTH},
 "yumSigning":{}}
JSON
)"
}
mk_yum_proxy "rocky-8-baseos-proxy"    "$ENTERPRISE_DNF_BASEOS_URL"
mk_yum_proxy "rocky-8-appstream-proxy" "$ENTERPRISE_DNF_APPSTREAM_URL"
mk_yum_proxy "epel-8-proxy"            "$ENTERPRISE_DNF_EPEL_URL"
echo -n "  rpm-internal:  "
create_repo yum/hosted '{"name":"rpm-internal","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"},"yum":{"repodataDepth":0,"deployPolicy":"STRICT"}}'

log "建 docker-hosted (給 podman push/pull，OSS 沒上游)"
echo -n "  docker-hosted: "
create_repo docker/hosted "$(cat <<JSON
{"name":"docker-hosted","online":true,
 "storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW_ONCE"},
 "docker":{"v1Enabled":false,"forceBasicAuth":true,"httpPort":$DOCKER_PORT}}
JSON
)"

log "建 raw-bundles (放 tarball / agent artifact)"
echo -n "  raw-bundles:   "
create_repo raw/hosted '{"name":"raw-bundles","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW"}}'

# --- 5. 印出 client 設定 ---
cat <<EOF

============================================================
✅ 中樞 Nexus 就緒
   UI:           http://${HUB_HOSTNAME}:${NEXUS_PORT}
   Docker:       ${HUB_HOSTNAME}:${DOCKER_PORT}
   admin 初始密碼: $ADMIN_PW   (請立刻改、刪掉 $ADMIN_PW_FILE)

接下來：
1. 登入 UI，改 admin 密碼。
2. Security → Realms → 啟用 "Docker Bearer Token Realm"
   （給 podman pull/push 用）
3. Security → Users → 建一個 service account 給 AI agent
   ex. svc-agent / 給 nx-repository-view-* 權限 / 產 token
4. 把下列值填到 bootstrap-client.sh 的 HUB_BASE 後分發到 10 台機器
============================================================
EOF
