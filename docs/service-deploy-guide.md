# Service Deploy Guide — Flask / Node 服務上線指南

給 dev team 用的「我有個新服務要上線」SOP。三層架構，依需求挑一層。

**核心原則：**
- **dev** 怎麼方便怎麼跑（hot reload 為主）
- **staging / 內部共用** 用 systemd user unit（不容器化、不裝多餘工具）
- **production** 用 podman + systemd Quadlet（image 從 Nexus 拉，跟 Nexus 本身一致）
- **絕不**用 PM2、forever、nohup、tmux 維持服務
- **絕不**用 `flask run` 當 production server

範本：[`templates/`](../templates/)。

- `templates/python-flask/` — 同步 Python，用 gunicorn
- `templates/python-fastapi/` — async Python (OpenAPI、websocket)，gunicorn + UvicornWorker
- `templates/nodejs/` — Express
- `templates/systemd-user/` — 不容器化、純 systemd

---

## 三層對照

| 層 | 場景 | 跑法 | 重啟 | log | 範本 |
|---|---|---|---|---|---|
| **L1 dev** | 自己改 code，要 hot reload | `flask --debug run` / `node --watch server.js` | 手動 | terminal | — |
| **L2 shared dev / staging** | 內部團隊共用、長期掛 | systemd `--user` 跑 gunicorn / node | 自動 | `journalctl --user -u <svc>` | `templates/systemd-user/` |
| **L3 production** | 給離線機使用者用的 | podman + systemd Quadlet，image 從 Nexus | 自動 | journalctl | `templates/python-flask/` `templates/nodejs/` |

---

## L1 dev：本機開發

```bash
# Flask
pip install -r requirements.txt
flask --app app run --debug          # http://127.0.0.1:5000

# Node
npm ci
npm run dev                          # node --watch server.js
```

沒有 SOP，就照舊。**唯一規定**：`pip` / `npm` 走 hub（`bootstrap-client.sh` 設好了，不要 override）。

---

## L2 staging：systemd user unit

適合「我要把這服務掛上去給 team 用」、但還沒做 image / CI 的時候。

### 步驟

1. 把 code 放在 `~/<service-name>/`
2. 從 `templates/systemd-user/myservice.service` 複製：
   ```bash
   mkdir -p ~/.config/systemd/user
   cp templates/systemd-user/myservice.service ~/.config/systemd/user/myapi.service
   # 編 ExecStart / WorkingDirectory / Description
   ```
3. 一次性開 lingering：
   ```bash
   loginctl enable-linger $(whoami)
   ```
4. 啟動：
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now myapi
   ```
5. 觀察：
   ```bash
   systemctl --user status myapi
   journalctl --user -u myapi -f
   ```
6. 更新：
   ```bash
   cd ~/myapi && git pull
   systemctl --user restart myapi
   ```

### Flask 一定要用 gunicorn

Flask 官方在首頁寫：**"the development server is not designed to be particularly efficient, stable, or secure"**。production 一律 gunicorn：

```ini
ExecStart=/usr/bin/python3.12 -m gunicorn -w 4 -b 127.0.0.1:8000 app:app
```

workers 數量：`(2 × CPU) + 1` 是 gunicorn 官方建議。

### 為什麼 systemd 而不是 PM2 / supervisor / nohup？

| 你想要 | systemd 怎麼給 |
|---|---|
| 開機自啟 | `WantedBy=default.target` + `enable-linger` |
| crash 重啟 | `Restart=on-failure` |
| log 集中 | `journalctl --user -u svc` |
| 多個 worker | gunicorn `-w 4`（Python） / node cluster 內建（Node） |
| 看 CPU/RAM | `systemctl --user status svc` 直接顯示 |
| zero downtime reload | `systemctl --user reload svc`（自己實作 SIGHUP handler） |

PM2 / supervisor 是 systemd 的 subset，多裝沒好處。

---

## L3 production：podman + systemd Quadlet

這層跟你們中樞跑 Nexus 的模式**一模一樣**。

### 步驟

1. **寫 Dockerfile**（範本 `templates/python-flask/Dockerfile` 或 `templates/nodejs/Dockerfile`）。
2. **本地 build & 試跑**：
   ```bash
   podman build -t myapp:dev .
   podman run --rm -p 8000:8000 myapp:dev
   curl http://127.0.0.1:8000/healthz
   ```
3. **推到 Nexus**（手動或讓 CI 推）：
   ```bash
   podman tag myapp:dev hub.internal:8082/myapp:v0.1.0
   podman login --tls-verify=false hub.internal:8082
   podman push --tls-verify=false hub.internal:8082/myapp:v0.1.0
   ```
4. **在 prod 機部署**（用 Quadlet）：
   ```bash
   mkdir -p ~/.config/containers/systemd
   cp templates/python-flask/myapp.container ~/.config/containers/systemd/
   # 編 Image=hub.internal:8082/myapp:v0.1.0

   systemctl --user daemon-reload
   systemctl --user start myapp
   journalctl --user -u myapp -f
   ```
5. **升版**：改 `.container` 裡的 `Image=...:v0.2.0` → `systemctl --user restart myapp`。

### Quadlet 是什麼

`~/.config/containers/systemd/foo.container` 是 podman 4.4+ 的「container as systemd unit」格式。寫一份 `.container`，systemd 自動產生 service unit，你 `systemctl --user start foo` 即可。比手寫 `podman run` + service file 乾淨。

### CI 自動化（Gitea Actions）

範本 `.gitea/workflows/build.yml` 已含：
- push → 跑測試 → build image → push 到 Nexus → tag latest + sha
- prod 機可以 `systemctl --user restart myapp` 拉新 latest（`AutoUpdate=registry` 也會週期性自動拉）

repo secrets 要設：`NX_USER` / `NX_PASS`（你的 svc-agent token）。

---

## 決策樹

```
新服務要上線
   │
   ├─ 只有我自己用，random port 試跑 → L1 dev
   │
   ├─ team 內部用，code 在 git 但沒做 image → L2 systemd user unit
   │   └─ 之後想升 production？ 加 Dockerfile + Quadlet → L3
   │
   └─ 給離線機使用者用 / 高可用 → 直接 L3 production
```

---

## 常見坑

| 症狀 | 原因 | 解 |
|---|---|---|
| 重開機後服務沒起 | 忘了 `loginctl enable-linger` | 跑一次 |
| `podman pull` 401 | Quadlet 用 root 跑、podman login 用 user 跑 | `systemctl --user` 跑 podman；或 unit 內加 `Secret=` |
| port < 1024 bind 失敗 | rootless 限制 | bind 高 port + nginx 前面轉發；或 `setcap CAP_NET_BIND_SERVICE` |
| Flask debug 模式上 prod | 用了 `flask run` | 改 gunicorn |
| log 看不到 | 程式自己寫到檔案 | 改寫到 stdout/stderr，journald 自動收 |
| podman pull 很慢 | NetApp 慢、image 大 | 多階段 build 瘦身、改用 alpine base（注意 glibc 相容） |

---

## 我什麼時候該升級層級？

| 訊號 | 該做什麼 |
|---|---|
| 服務常被誤殺 / 開機要手動起 | L1 → L2 |
| 別人想 deploy 但配置很煩 | L2 → L3（裝成 image）|
| 要 rollback 到舊版 | L2 → L3（image 有 tag） |
| 多台同時跑同一服務 | L3，N 台機器 pull 同 tag |
| 服務間要互相呼叫 | L3 + Gitea 寫個 docker-compose 風格的多 .container |
