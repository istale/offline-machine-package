# AI Agent Cookbook — 離線 Nexus 中樞操作手冊

給 AI agent（也給工程師）用的指令大全。所有操作只透過 **REST API** 或 **podman / pip / npm / dnf CLI**，不需要登 UI。

本 repo 的交付流分兩類：

- **Ecosystem flows**：`pypi`、`npm`、`images`、`rpms`、`repos`
- **Raw-bundles flows**：`uv`、`hermes`

前者對應標準下游工具鏈；後者發到 Nexus `raw-bundles/`，再由專用安裝腳本落地。

## 0. 環境變數（agent 開工前 export）

```bash
export HUB_BASE="http://hub.internal:8081"
export DOCKER_HOST="hub.internal:8082"
export NX_USER="svc-agent"
export NX_PASS="<token>"          # 用 Nexus UI 建 user token
export GITEA_BASE="http://gitea.internal:3000"
export GITEA_TOKEN="<token>"
```

---

## 1. 查套件存不存在（先查再動）

```bash
# PyPI
curl -s "$HUB_BASE/service/rest/v1/search?repository=pypi-group&name=pandas" | jq '.items[].version' | sort -u

# npm
curl -s "$HUB_BASE/service/rest/v1/search?repository=npm-group&name=react" | jq '.items[].version' | sort -u

# Docker image
curl -s "$HUB_BASE/service/rest/v1/search?repository=docker-hosted&name=python" | jq '.items[].version'

# RPM
curl -s "$HUB_BASE/service/rest/v1/search?repository=rocky-8-baseos-proxy&name=htop" | jq '.items[].version'
```

決策樹：
- 有 → 直接 `pip install` / `podman pull`
- 沒有 → 走 sideload (見 §4)

---

## 2. 用套件（client 端已被 bootstrap-client.sh 設定好）

```bash
pip install pandas==2.2.0          # 走 pypi-group
npm install react@18               # 走 npm-group
dnf install htop                   # 走 yum proxies
podman pull python:3.12            # 走 docker-hosted
```

---

## 3. 上傳自製產物

### 3.1 Python wheel
```bash
python -m build                    # 產 dist/*.whl
curl -u "$NX_USER:$NX_PASS" --upload-file dist/mypkg-1.0-py3-none-any.whl \
  "$HUB_BASE/repository/pypi-internal/"
```

### 3.2 npm 套件
```bash
npm pack                           # 產 mypkg-1.0.0.tgz
curl -u "$NX_USER:$NX_PASS" -H 'Content-Type: application/octet-stream' \
  --upload-file mypkg-1.0.0.tgz \
  "$HUB_BASE/repository/npm-internal/"
```

### 3.3 容器 image
```bash
podman login -u "$NX_USER" -p "$NX_PASS" "$DOCKER_HOST" --tls-verify=false
podman tag myapp:1.0 "$DOCKER_HOST/myapp:1.0"
podman push --tls-verify=false "$DOCKER_HOST/myapp:1.0"
```

### 3.4 raw artifact（tarball / 文件 / 任何檔）
```bash
curl -u "$NX_USER:$NX_PASS" --upload-file output.tar.gz \
  "$HUB_BASE/repository/raw-bundles/myproject/2026-06-20/output.tar.gz"
```

---

## 4. OSS 沒有的內容 → Sideload 流程

**判斷條件**：§1 查不到 + IT 嚴審不會收。

### 4.1 Ecosystem flows：在 Mac 上打包
```bash
# 先編 manifests/*.txt
vi manifests/pypi.txt      # 例如加 pandas==2.2.0
vi manifests/npm.txt       # 例如加 lodash@4.17.21
vi manifests/images.txt    # 例如加 docker.io/library/nginx:1.27
vi manifests/rpms.txt
vi manifests/repos.txt

# 再跑對應 sideload 腳本
./scripts/mac/sideload-pypi.sh
./scripts/mac/sideload-npm.sh
./scripts/mac/sideload-images.sh
./scripts/mac/sideload-rpms.sh
./scripts/mac/sideload-repos.sh

# 或一次全跑
./scripts/mac/sideload-all.sh
```
產出 `dist/*-bundle-*.tar.gz`。

### 4.2 Ecosystem flows：搬到 hub 後上傳
```bash
export HUB_BASE=http://127.0.0.1:8081
export NX_USER=svc-agent
export NX_PASS=<token>
export DOCKER_HOST_REG=127.0.0.1:8082
export GITEA_BASE=http://gitea.internal:3000
export GITEA_TOKEN=<token>

./scripts/hub/upload-pypi.sh   dist/pypi-bundle-XXX.tar.gz
./scripts/hub/upload-npm.sh    dist/npm-bundle-XXX.tar.gz
./scripts/hub/upload-images.sh dist/images-bundle-XXX.tar.gz
./scripts/hub/upload-rpms.sh   dist/rpms-bundle-XXX.tar.gz
./scripts/hub/upload-repos.sh  dist/repos-bundle-XXX.tar.gz

# 或一次全跑最新 bundle
./scripts/hub/upload-all.sh
```
完成。Client 端**完全無感**，下次 `pip install pandas` 就會命中 `pypi-internal`。

### 4.3 Raw-bundles flows：`uv` / `hermes`

這兩個不是新的套件倉庫型別，而是「可安裝 tarball」。

```bash
# Mac 上
vi manifests/uv.txt
vi manifests/hermes.txt
./scripts/mac/sideload-uv.sh
./scripts/mac/sideload-hermes.sh

# Hub 上
./scripts/hub/upload-uv.sh dist/uv-bundle-XXX.tar.gz
./scripts/hub/upload-hermes.sh dist/hermes-bundle-XXX.tar.gz

# Client 上
sudo ./scripts/client/install-uv.sh
sudo ./scripts/client/install-hermes.sh
```

這些 bundle 會發到：

- `raw-bundles/uv/{timestamped,latest.tar.gz}`
- `raw-bundles/hermes/{timestamped,latest.tar.gz}`

---

## 5. 觸發 CI/CD（Gitea Actions）

### 5.1 觸發 workflow
```bash
curl -X POST -H "Authorization: token $GITEA_TOKEN" \
  -H 'Content-Type: application/json' \
  "$GITEA_BASE/api/v1/repos/team/myproj/actions/workflows/build.yml/dispatches" \
  -d '{"ref":"main","inputs":{}}'
```

### 5.2 Workflow 範本（`.gitea/workflows/build.yml`）
```yaml
name: build
on: [push, workflow_dispatch]
jobs:
  test:
    runs-on: self-hosted
    container:
      image: hub.internal:8082/python:3.12
    steps:
      - uses: actions/checkout@v4
      - run: pip install -e .[dev]
      - run: pytest
  release:
    needs: test
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - name: build & push image
        run: |
          podman build -t hub.internal:8082/myapp:${{ github.sha }} .
          podman push --tls-verify=false hub.internal:8082/myapp:${{ github.sha }}
```

### 5.3 查 run 狀態
```bash
curl -H "Authorization: token $GITEA_TOKEN" \
  "$GITEA_BASE/api/v1/repos/team/myproj/actions/runs" | jq '.workflow_runs[0]'
```

---

## 6. Repo 健康檢查（每天可排 cron）

```bash
# Nexus 整體狀態
curl -sf "$HUB_BASE/service/rest/v1/status" && echo "Nexus OK"

# 上游連線狀態（proxy 是不是被 auto-block 了）
curl -u "$NX_USER:$NX_PASS" \
  "$HUB_BASE/service/rest/v1/repositories" | \
  jq '.[] | select(.type=="proxy") | {name, online: .online}'

# 磁碟使用
curl -u "$NX_USER:$NX_PASS" \
  "$HUB_BASE/service/rest/v1/blobstores" | jq '.[] | {name, totalSizeInBytes, availableSpaceInBytes}'
```

---

## 7. 常見故障決策樹

| 症狀 | 先查 | 處理 |
|---|---|---|
| `pip install` 404 | §1 查存不存在 | 不在 → §4 sideload；在 → 看 negativeCache 有沒 cache 住 |
| `podman pull` 401 | `podman login` 過嗎 | 用 NX_USER/NX_PASS 重 login |
| `dnf` 還在連外網 | `/etc/yum.repos.d/` 有舊 .repo | bootstrap-client.sh 重跑 |
| Proxy 上游 block | §6 查 online 狀態 | UI → repo → "remove from blocklist" 或等 auto-unblock |
| Nexus 滿了 | §6 查 blobstore | 清 raw-bundles 舊資料 / 加 NetApp 配額 |

---

## 8. 規則總結（agent 自我約束）

1. **先查再動** — §1 是每次操作的第一步
2. **OSS 沒有不要硬等 IT** — 走 §4 sideload，工程師審批走另一條路
3. **Client 永遠只認 group repo** — 不要繞過去打 proxy 或 internal
4. **HTTP 是設計選擇** — 不要嘗試開 TLS / 加 CA
5. **產物都進 Nexus/Gitea 的正式落點** — ecosystem flows 進 hosted/group 生態系，tool/app bundles 進 `raw-bundles/`
