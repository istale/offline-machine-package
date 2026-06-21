# Deployment Checklist — 從零到生產的 18 步

把這份印出來，照順序打勾。每步都有明確指令 + 通過條件，不要跳。

預估時間：**首次部署 1 天**（含 IT 對接 + 三方驗證）；之後加新離線機只剩 §4。

---

## Phase A. Pre-flight（在 Mac 上做，~30 min）

### ☐ 1. 收齊變數

打開一個臨時 note，把這些值填好（不知道的去問 IT）：

```
HUB_HOSTNAME              =                              # 例 hub.internal
HUB_IP                    =                              # 給離線機加 /etc/hosts 用
NEXUS_DATA                =                              # NetApp 路徑，例 /srv/nexus-data
ENTERPRISE_OSS_BASE       =                              # 例 http://oss.corp:8081
ENTERPRISE_PYPI_URL       =                              # 例 ${OSS}/repository/pypi/
ENTERPRISE_NPM_URL        =                              # 例 ${OSS}/repository/npm/
ENTERPRISE_DNF_BASEOS_URL =                              #
ENTERPRISE_DNF_APPSTREAM_URL =                           #
ENTERPRISE_DNF_EPEL_URL   =                              #
OSS_USER                  =                              # 可留空
OSS_PASS                  =                              # 可留空
GITEA_BASE                =                              # 例 http://gitea.internal:3000
GITEA_TOKEN               =                              # 進 Gitea User Settings → Apps → Create Token
```

**通過條件**：每行都有值或標記「無」。

### ☐ 2. 把所有 bundle 準備好（重跑一次確認新鮮）

```bash
cd /Users/istale/Documents/offline-machine-package
./scripts/mac/prepare-nexus-image.sh    # 1.1 GB nexus3 + 六個 base image
./scripts/mac/sideload-uv.sh            # 47 MB uv
./scripts/mac/sideload-hermes.sh        # 204 MB Hermes
# pypi/npm/repos 視 manifest 內容，第一次可空
ls -lh dist/
```

**通過條件**：`dist/` 至少有 `nexus3-image-bundle-*.tar.gz`, `uv-bundle-*.tar.gz`, `hermes-bundle-*.tar.gz`。

### ☐ 3. 把 repo + bundles 一起搬到中樞機 inbox

```bash
# 把整個 repo (~含腳本/docs) + 所有 dist/*.tar.gz 一起搬
# 路徑視你公司 SOP（scp / USB / 跳板）
scp -r /Users/istale/Documents/offline-machine-package webadmin@$HUB:~/
scp dist/*.tar.gz webadmin@$HUB:~/inbox/
```

**通過條件**：在 hub 機上 `ls ~/offline-machine-package/scripts` 看得到所有腳本；`ls ~/inbox/` 看得到 tarball。

---

## Phase B. Hub bring-up（在中樞機，~45 min）

### ☐ 4. 載入 base images

```bash
ssh webadmin@$HUB
mkdir -p ~/nexus-bundle
tar -C ~/nexus-bundle -xzf ~/inbox/nexus3-image-bundle-*.tar.gz
cd ~/nexus-bundle && ./load-images.sh
podman images           # 七個 image 都在
```

**通過條件**：`podman images` 列出 sonatype/nexus3、rockylinux:8.10、python:3.12-slim、node:22、redis:7、postgres:16、gitea/act_runner。

### ☐ 5. 填 `bootstrap-hub.sh` 的變數，跑

```bash
cd ~/offline-machine-package
vi scripts/hub/bootstrap-hub.sh        # 把 §1 那 12 行變數全填
./scripts/hub/bootstrap-hub.sh
```

**通過條件**：腳本最後印出 admin 初始密碼，並提醒「請改密碼」。

### ☐ 6. Nexus UI 一次性手動設定

開 `http://$HUB:8081/`，做這四件事：

- ☐ **改 admin 密碼**（首次登入會強制）→ 寫進密管
- ☐ **Security → Realms** → 把 "Docker Bearer Token Realm" 從 Available 拖到 Active → Save
- ☐ **Security → Users → Create local user**
  - id: `svc-agent`
  - email: 隨便
  - roles: 給 `nx-anonymous` + 自建一個 role 含 `nx-repository-view-*-*-*`（簡單做法：暫時給 admin role，事後縮）
- ☐ **以 svc-agent 登入 → User → Tokens → Generate user token** → 兩段碼合在一起就是 NX_PASS

**通過條件**：
```bash
export NX_USER=svc-agent NX_PASS=<剛拿的 token>
curl -u $NX_USER:$NX_PASS http://localhost:8081/service/rest/v1/status && echo OK
```

### ☐ 7. 灌 uv + hermes 到 raw-bundles

```bash
export HUB_BASE=http://127.0.0.1:8081
./scripts/hub/upload-uv.sh     ~/inbox/uv-bundle-*.tar.gz
./scripts/hub/upload-hermes.sh ~/inbox/hermes-bundle-*.tar.gz
```

**通過條件**：
```bash
curl -sI -u $NX_USER:$NX_PASS \
  http://127.0.0.1:8081/repository/raw-bundles/uv/latest.tar.gz | head -1
# HTTP/1.1 200 OK
```

### ☐ 8. 註冊 Gitea Actions runner

在 Gitea 上：**Site Admin → Actions → Runners → Create new Runner** → 複製 token。

```bash
export GITEA_BASE=http://gitea.internal:3000
export RUNNER_TOKEN=<剛拿的>
./scripts/hub/register-actions-runner.sh
```

**通過條件**：Gitea Admin → Runners 看到 `hub-runner-1` 狀態為 online。
```bash
journalctl --user -u act-runner -n 20    # 應該看到 "Runner registered successfully"
```

---

## Phase C. Client roll-out（每台離線機，~10 min/台）

### ☐ 9. 準備 client bootstrap

在 Mac 上：
```bash
vi scripts/client/bootstrap-client.sh    # 填 HUB_HOSTNAME
```
搬到第一台離線機（先做一台驗證，再 fan-out）：
```bash
scp scripts/client/bootstrap-client.sh user@dev1:~/
```

### ☐ 10. 跑 bootstrap-client.sh

```bash
ssh user@dev1
sudo ./bootstrap-client.sh
```

**通過條件**：
```bash
dnf repolist enabled                 # 只看到 internal-* 四個
pip3 config list                     # index-url 指 hub
podman info | grep -A1 insecure      # 看到中樞 docker host
```

### ☐ 11. End-to-end 驗證（最重要的一步）

在 dev1：
```bash
# A. ecosystem
sudo dnf install -y htop && htop --version       # via dnf proxy
pip3 install --user requests && python3 -c 'import requests'  # via pypi-group
podman pull python:3.12 && podman run --rm python:3.12 -c 'print("hi")'  # via docker-hosted

# B. raw-bundles
sudo HUB_BASE=http://$HUB_HOSTNAME:8081 ./install-uv.sh   # (從 hub 抓)
source /etc/profile.d/uv.sh
uv run python -c 'import sys;print(sys.executable)'  # 應印 /usr/bin/python3.12
```

**通過條件**：四條全綠。任一條失敗回 §3.1 hub 健康檢查。

### ☐ 12. Fan-out 到剩餘 9+ 台

```bash
for h in dev2 dev3 dev4 ... prod1 prod2; do
  scp scripts/client/bootstrap-client.sh $h:~/
  ssh $h sudo ./bootstrap-client.sh
done
```

**通過條件**：抽 2 台跑 §11 同樣 4 條，全綠。

---

## Phase D. CI/CD 通電（~30 min）

### ☐ 13. 把這個 repo 也丟進 Gitea

在 Mac：
```bash
echo "/Users/istale/Documents/offline-machine-package/  admin/offline-machine-package" >> manifests/repos.txt
./scripts/mac/sideload-repos.sh
scp dist/repos-bundle-*.tar.gz webadmin@$HUB:~/inbox/
```
在 hub：
```bash
./scripts/hub/upload-repos.sh ~/inbox/repos-bundle-*.tar.gz
```

**通過條件**：Gitea 看到 `admin/offline-machine-package` repo。

### ☐ 14. 跑一條最簡單的 workflow 驗證 runner

在 Gitea repo 新增 `.gitea/workflows/smoke.yml`：
```yaml
name: smoke
on: [push, workflow_dispatch]
jobs:
  hello:
    runs-on: self-hosted
    container:
      image: hub.internal:8082/python:3.12-slim
    steps:
      - run: python -c 'print("ci works")'
```

**通過條件**：Actions tab 看到 ✅ 綠勾。

---

## Phase E. 收尾（~30 min）

### ☐ 15. Hub 健康檢查 cron

在 hub：
```bash
crontab -l
# 加一行：
# 0 8 * * 1 curl -sf http://127.0.0.1:8081/service/rest/v1/status || echo "Nexus DOWN" | mail -s alert ops@corp
```

### ☐ 16. 備份 NetApp snapshot 排程

跟存儲團隊確認 `$NEXUS_DATA` 有 daily snapshot。

### ☐ 17. 把 admin 密碼 + svc-agent token + GITEA_TOKEN 進密管

不要留在 shell history。

### ☐ 18. 公告 dev team

寫一封：「即日起 pip / npm / dnf / podman 都走 `hub.internal`，自動。要加套件請發 PR 改 `manifests/*.txt`。怎麼跑服務看 [docs/service-deploy-guide.md](docs/service-deploy-guide.md)。」

---

## 完成標準

打完 18 個勾後，原始 goal 達成度：

- ✅ 10+ 離線機共用一個套件來源
- ✅ pip / npm / dnf 不再手動傳 USB
- ✅ Gitea + Actions 已通電（CI/CD 流程可用）
- ✅ uv / Hermes 等 AI agent 工具可一鍵裝
- ✅ 加套件變 PR-able、AI agent 可代勞

---

## 卡關時去哪

| 階段卡 | 看 |
|---|---|
| §4–7 hub 起不來 | `docs/operator-runbook.md` §3.1 |
| §8 runner 連不上 Gitea | `journalctl --user -u act-runner -f` + 檢查 `RUNNER_TOKEN` 是否複製錯 |
| §11 client 走不通 hub | `docs/operator-runbook.md` §4.3 |
| 套件 OSS 沒有 | `docs/operator-runbook.md` §1.2 sideload 流程 |
