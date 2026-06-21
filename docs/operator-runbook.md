# Operator Runbook — 人類維運 SOP

給工程師看的日常操作指南。**情境驅動**：先描述「你遇到什麼」，再給步驟。
AI agent 也可以照這份做事，但 agent 的精簡版在 `AGENTS.md`。

---

## 分類總覽

這個 repo 有兩種交付流，先分清楚再做事：

| 類別 | 包含什麼 | 下游怎麼吃 |
|---|---|---|
| **Ecosystem flows** | `pypi`、`npm`、`images`、`rpms`、`repos` | `pip` / `npm` / `podman` / `dnf` / `git` 直接用 |
| **Raw-bundles flows** | `uv`、`hermes` | 從 Nexus `raw-bundles/` 下載，再跑安裝腳本 |

判斷規則：

- 如果 client 端是用標準生態系工具直接消費，當作 **ecosystem flow**
- 如果是 tarball 發佈後還要 `install-*.sh` 落地，當作 **raw-bundles flow**

`uv` 跟 `hermes` 不是新的套件倉庫型別，只是 installable bundle。

---

## 0. 角色與環境

| 角色 | 身分 / 機器 | 你會做什麼 |
|---|---|---|
| **打包者** | Mac (online) | 編 `manifests/*.txt`、跑 `scripts/mac/sideload-*.sh`、把 `dist/*.tar.gz` 搬到中樞 |
| **中樞管理員** | hub 機，使用者 `webadmin` | 跑 `scripts/hub/*.sh`、看 Nexus UI、處理故障 |
| **離線機使用者** | 10+ dev/prod 機 | 平常只用 `pip` `npm` `dnf` `podman`，不該感知中樞細節 |

**一定要先設好的環境變數**（每次新開 shell 都要 export，或寫進 `~/.bashrc`）：

```bash
# 打包者（Mac）— 不需要任何環境變數，sideload-*.sh 都自帶預設值

# 中樞管理員（hub 機）
export HUB_BASE=http://127.0.0.1:8081
export DOCKER_HOST_REG=127.0.0.1:8082
export NX_USER=svc-agent             # 在 Nexus UI 建好的 service account
export NX_PASS=<user token>          # 不是登入密碼，是 user token
export GITEA_BASE=http://gitea.internal:3000
export GITEA_TOKEN=<gitea token>
```

---

## 1. 日常情境

### 1.1 「某個 dev 跟我說 `pip install X` 失敗」

**先確認失敗原因**（叫 dev 截圖或自己 ssh 上去）：

| 訊息 | 真正原因 | 處理 |
|---|---|---|
| `Could not find a version that satisfies` | 套件不在 group 裡 | 進 §1.2 流程加進去 |
| `Connection refused / timeout` | client 設定壞了 / Nexus 掛了 | §3.1 健康檢查 |
| `Hash mismatch` | proxy 上游檔壞了 | Nexus UI → repo → Admin → Invalidate Cache |
| `SSL: CERTIFICATE_VERIFY_FAILED` | 有人偷加 https | 我們不用 TLS，檢查 `pip.conf` 是不是被改過 |

### 1.2 「OSS 沒有，要加新套件 / image / repo」

**標準流程**（PR-able、agent-able、可重複）：

1. Mac 上開分支，編 manifest：
   ```bash
   cd ~/Documents/offline-machine-package
   git checkout -b add-pandas
   echo "pandas==2.2.0" >> manifests/pypi.txt
   git diff       # 自我審
   ```
2. 跑 sideload：
   ```bash
   ./scripts/mac/sideload-pypi.sh
   ```
   - 看到 `[pypi] ✅ clean x86_64/manylinux wheels` 才算過
   - 失敗的話看 §4.1
3. 產出 `dist/pypi-bundle-YYYYMMDD-HHMMSS.tar.gz`。**先 commit manifest**，再搬 tarball。
4. 搬到中樞（USB / 跳板 / `scp`，看你家 SOP）。
5. 中樞上：
   ```bash
   cd ~/scripts   # 或你放 scripts 的地方
   ./hub/upload-pypi.sh ~/inbox/pypi-bundle-XXX.tar.gz
   ```
6. 驗證（任一離線機）：
   ```bash
   pip install pandas==2.2.0     # 成功即收工
   ```

**多種一起加**：manifest 多種一起編，Mac 上 `./scripts/mac/sideload-all.sh`，中樞 `./scripts/hub/upload-all.sh`。

### 1.3 「要把一個 GitHub repo 搬進 Gitea」

1. Mac 編 `manifests/repos.txt`：
   ```
   https://github.com/your-org/proj-x.git   team/proj-x
   ```
2. `./scripts/mac/sideload-repos.sh` → `dist/repos-bundle-*.tar.gz`
3. 中樞：
   ```bash
   ./hub/upload-repos.sh ~/inbox/repos-bundle-XXX.tar.gz
   ```
   會自動：建 org `team`（如不存在）→ 建 repo → push 所有 branch/tag
4. dev 端 `git clone http://gitea.internal:3000/team/proj-x.git` 即可

**重 sync 同一 repo**：再跑一次 sideload-repos.sh，會 `git remote update`，只帶差異。

### 1.4 「上游 GitHub repo 有新 commit 要同步」

跟 1.3 完全一樣。`git clone --mirror` 第二次會變成 `git remote update`，只抓 delta。

### 1.5 「裝 / 升級 Hermes Agent Desktop」

Hermes Agent (Nous Research, MIT) 是 Electron-style 桌面 agent，內含 Node + Python venv + Playwright Chromium。安裝路徑寫死在 venv shebang 裡，所以**打包與安裝路徑必須一致**，預設 `/opt/hermes`。

**升級 / 重打包**（Mac）：
```bash
vi manifests/hermes.txt          # 改 HERMES_REF=v0.17.0 之類
./scripts/mac/sideload-hermes.sh # 容器內跑官方 install.sh，產 dist/hermes-bundle-*.tar.gz
```

**發布到中樞**：
```bash
./scripts/hub/upload-hermes.sh dist/hermes-bundle-XXX.tar.gz
# 會自動更新 raw-bundles/hermes/latest.tar.gz alias
```

**離線機安裝**（每台 desktop 一次）：
```bash
sudo ./scripts/client/install-hermes.sh
source /etc/profile.d/hermes.sh
hermes --help
```

**自訂安裝路徑**（裝之前或之後都可以）：

Hermes 寫三個位置：
| 路徑 | 內容 | 能否改 |
|---|---|---|
| `/opt/hermes` (`$HERMES_HOME`) | 使用者設定、API key、log、session | ✅ 隨時改 |
| `/usr/local/lib/hermes-agent` | 程式碼、Python venv、Playwright cache | ⚠️ venv shebang 寫死 → 只能用 **symlink** |
| `/usr/local/bin/hermes` | 進入點 | ✅ 隨時改 |

**裝之前指定**（推薦，最乾淨）：
```bash
sudo HERMES_HOME=/data/hermes \
     HERMES_LIB=/data/hermes-code/hermes-agent \
     ./scripts/client/install-hermes.sh
# script 會自動在 /usr/local/lib/hermes-agent 建 symlink 指到 HERMES_LIB
```

**裝完想搬資料目錄** (`$HERMES_HOME`)：
```bash
sudo systemctl stop hermes 2>/dev/null   # 若有跑成 service
sudo mv /opt/hermes /data/hermes-data
sudo sed -i 's|/opt/hermes|/data/hermes-data|' /etc/profile.d/hermes.sh
# 重開 shell 或 source /etc/profile.d/hermes.sh
```

**裝完想搬 code 目錄**（用 symlink，不要 mv 走）：
```bash
sudo mv /usr/local/lib/hermes-agent /data/hermes-code/hermes-agent
sudo ln -s /data/hermes-code/hermes-agent /usr/local/lib/hermes-agent
# venv shebang 仍指向 /usr/local/lib/...，但實體在 NetApp / 其他位置
```

**常見問題**：
- shebang `No such file` → code 目錄被直接 mv 走（沒留 symlink）。建回 symlink 即可。
- Chromium 啟動失敗少 lib → install-hermes.sh 開頭 dnf install 那串補齊，特別是 `nss atk cups-libs`。
- 升級後想保留舊版 → install-hermes.sh 會自動把舊路徑搬到 `.bak.YYYYMMDD-HHMMSS`，要還原直接 mv 回來。

### 1.6 「裝 / 升級 uv」

uv 是 Astral 的 Python 工具，許多 sample code / MCP server 都用 `uv run` 或 `uvx`。我們只裝 binary，**強制走系統 python3.12 並禁止下載 Python**，所以離線完全跑得起來。

**升級 / 重打包**（Mac）：
```bash
vi manifests/uv.txt              # 改 UV_VERSION=0.5.7 之類；或保持 latest
./scripts/mac/sideload-uv.sh     # 抓 GitHub release → dist/uv-bundle-*.tar.gz
```

**發布到中樞**：
```bash
./scripts/hub/upload-uv.sh dist/uv-bundle-XXX.tar.gz
```

**離線機安裝**：
```bash
sudo ./scripts/client/install-uv.sh
# 新 shell:  uv --version  / uv run python -c 'import sys;print(sys.executable)'
# 後者應印 /usr/bin/python3.12
```

**設計重點**：
- `/etc/profile.d/uv.sh` 寫死 `UV_PYTHON_PREFERENCE=only-system` + `UV_PYTHON_DOWNLOADS=never`
- uv 自動讀 `/etc/pip.conf` → 套件解析走 hub `pypi-group`
- 工程師照 README 抄 `uv add x` / `uvx ruff check` 都會成功，零學習成本

**故障**：
- `uv` 抱怨找不到 Python → `dnf install python3.12`，bootstrap-client.sh 通常已裝
- `uv` 想下載 Python → 檢查 `env | grep UV_`，profile 沒 source 到
- `uvx <tool>` 卡在解析 → 確認 `/etc/pip.conf` 有 `trusted-host = $HUB_HOSTNAME`

### 1.7 「新進一台離線機」

1. 對方先裝好 RHEL 8.10、能連到中樞（ping `hub.internal`）。
2. 把 `scripts/client/bootstrap-client.sh` 拷過去（USB 或臨時 scp）。
3. 編 `HUB_HOSTNAME`，`sudo ./bootstrap-client.sh`。
4. 驗證：
   ```bash
   dnf repolist enabled
   pip3 install --dry-run pandas
   podman pull python:3.12
   ```

### 1.8 「Nexus admin 密碼忘了」

1. 中樞上：
   ```bash
   sudo cat /srv/nexus-data/admin.password 2>/dev/null
   ```
   （只有從未改過才會有）
2. 沒有的話，停服務、編 security.xml：
   ```bash
   systemctl --user stop nexus
   vi /srv/nexus-data/db/security/security.xml   # 找 admin user，刪掉，重啟會重產
   systemctl --user start nexus
   ```
   重啟後 `admin.password` 又會出現。

---

## 2. 定期維護（建議每週/每月）

### 2.1 每週

- **掃 Nexus 健康**（中樞）：
  ```bash
  curl -sf $HUB_BASE/service/rest/v1/status && echo OK
  curl -u $NX_USER:$NX_PASS $HUB_BASE/service/rest/v1/repositories \
    | jq '.[] | select(.type=="proxy") | {name, online}'
  ```
  發現 `online: false` → 進 UI → 該 repo → "Health Check" → 解 block
- **掃磁碟**：
  ```bash
  curl -u $NX_USER:$NX_PASS $HUB_BASE/service/rest/v1/blobstores | jq
  df -h /srv/nexus-data
  ```
  NetApp 剩 < 15% 要呼叫存儲團隊或清 §2.3

### 2.2 每月

- **看 Gitea Actions 是否被卡**：UI → Actions → 看有沒有一堆 queue 住的 job
- **dev 機抽一台**重跑 `bootstrap-client.sh`，確認設定沒漂移
- **review `manifests/`**：把不再用的東西刪掉（注意：刪 manifest 不會刪 Nexus 內已上傳的東西，要手動進 UI 刪）

### 2.3 清空間

按佔比降冪處理：

1. **舊 base image** — 同一個 image 多版本累積。UI → docker-hosted → 刪舊 tag → Tasks → Run **"Admin - Compact blob store"**
2. **舊 raw artifact** — `raw-bundles` 通常會被當垃圾場。UI 直接刪資料夾，記得跑 compact task
3. **proxy cache 失效資料** — Tasks → 跑 "Maintenance - Rebuild repository search index" 和 "Maintenance - Storage facet cleanup"

---

## 3. 故障處理

### 3.1 「Nexus 整個無法連」

```bash
# 1. 服務狀態
systemctl --user status nexus

# 2. container 還在嗎
podman ps -a | grep nexus

# 3. 看 log
podman logs --tail=200 nexus

# 4. 磁碟 / NetApp 還掛著嗎
mount | grep nexus-data
df -h /srv/nexus-data
```

**最常見原因**：
- NetApp mount lost → 重新掛、`systemctl --user restart nexus`
- OOM → systemd unit 裡 `--memory=4g` 加大、restart
- 升級 Nexus 後 schema migrate 卡住 → log 會說，等就好（首次 5–10 分鐘）

### 3.2 「client `dnf` 還在連外網」

```bash
ls /etc/yum.repos.d/         # 該只有 internal.repo + *.disabled
sudo dnf clean all
sudo dnf repolist
```
如果還在打外網，看 `/etc/dnf/dnf.conf` 有沒被加 `mirrorlist` 或 `proxy` 設定。

### 3.3 「`podman pull` 401 Unauthorized」

```bash
podman login --tls-verify=false $DOCKER_HOST_REG
# 用 NX_USER / NX_PASS 登入
```
Nexus UI → Security → Realms → 確認 **Docker Bearer Token Realm** 在 Active。

### 3.4 「Gitea push reject: repository is empty / locked」

`upload-repos.sh` 失敗常見：
- 目標 repo 已存在但是非空 → 進 Gitea UI 砍掉 repo 重來，或者改用 `--force`（小心覆蓋）
- token 過期 → Gitea UI → Settings → Applications → 重生 token，重新 export

### 3.5 「sideload-pypi 出現 sdist (.tar.gz)」

容器內找不到 binary wheel，會 fallback 抓 source。離線機沒 compiler 通常會炸。

```bash
# 看哪幾個是 sdist
tar -tzf dist/pypi-bundle-XXX.tar.gz | grep '\.tar\.gz$'
```

對策：
- 換版本（很多套件早期版才有 binary）
- 或把該套件加進「離線機需要的 build 工具」清單（`manifests/rpms.txt` 加 `gcc`, `python3.12-devel`），同時容器內也裝
- 真的不行：在中樞自己 build wheel → 上 `pypi-internal`

---

## 4. 排錯參考表

### 4.1 sideload 階段常見錯

| 訊息 | 原因 | 解 |
|---|---|---|
| `docker: command not found` | OrbStack / Docker Desktop 沒開 | 開它 |
| `cannot connect to Docker daemon` | 同上 | 同上 |
| `manifest unknown` | image tag 打錯 | 修 `manifests/images.txt` |
| `❌ contaminated:` 有 arm64/macosx | sideload script 被人改壞了 `--platform` | 還原 script |
| pip `ERROR: No matching distribution` | 套件名/版本不存在於 PyPI | 確認 spelling、查 pypi.org |

### 4.2 upload 階段常見錯

| 訊息 | 原因 | 解 |
|---|---|---|
| `curl: 401` | NX_USER/NX_PASS 沒 export 或錯 | 重新 export |
| `curl: 405 Method Not Allowed` | repo 不是 hosted 或被設成 read-only | UI 改 writePolicy=ALLOW |
| `podman push: blob upload invalid` | docker-hosted 沒開 v2，或 Realm 沒啟 | UI → Realms |
| Gitea `422 already exists` | repo 已建 | 正常，會繼續 push |

### 4.3 client 階段常見錯

| 症狀 | 原因 | 解 |
|---|---|---|
| `pip install` 一直 hang | proxy auto-block 上游 OSS | UI → repo → Health → 解 block |
| `dnf` GPG 驗證失敗 | 我們 baseurl 沒設 gpgcheck=0 | bootstrap-client.sh 已含 `gpgcheck=0`，檢查有沒被改 |
| `podman pull` 慢到爆 | NetApp / 網路 | 跟 IT 講；先用 `--retry` |

---

## 5. 安全 / 權限慣例

- **Nexus admin 密碼**：只有 1–2 人知道，密碼進公司密管。
- **`svc-agent` token**：自動化用，給 `nx-repository-view-*` 即可，**不要給 admin 權限**。
- **Gitea token**：每個自動化任務各自一支，方便事後 revoke。
- **HTTP only** 是設計選擇 — 不要因為「習慣」自己加 nginx + 自簽。所有腳本都假設 HTTP。

---

## 6. 升級 / 變更管理

| 變更 | 影響範圍 | 步驟 |
|---|---|---|
| Nexus 大版本升級 | 全公司 | 先 backup `/srv/nexus-data`（NetApp snapshot 就好）→ 改 systemd unit 內 image tag → restart → 看 log 5–10 分鐘 |
| 加新 base image | 後續 build | 編 `manifests/images.txt` → sideload → upload |
| 換 NetApp 掛載點 | 全公司 | 停 Nexus → rsync 整包 → 改 unit ExecStart `-v` → 啟動 |
| 新增第二台中樞 | 不建議 | 先跟所有 stakeholder 對齊，這份 SOP 沒涵蓋 |

---

## 7. 緊急聯絡

依貴司實際填寫：

- NetApp / 存儲：
- 網路 / OSS endpoint：
- Gitea 維運：
- 本 SOP 維護者：
