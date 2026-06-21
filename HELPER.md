# HELPER.md — 給幫忙抓檔案的人

謝謝你幫忙。你的工作很單純：**從 GitHub 下載一個檔案，送進公司**。不用懂裡面的內容，也不用裝任何開發工具。

---

## 你要做的三件事

### 1. 下載

到我給你的 GitHub Release 頁面，下載**所有檔案**（包含 `.sha256`）。
通常是：
- `offline-machine-package-MEGA-YYYYMMDD-HHMMSS.tar.gz`（單一檔案）
**或**
- `offline-machine-package-MEGA-YYYYMMDD-HHMMSS.tar.gz.part00`
- `offline-machine-package-MEGA-YYYYMMDD-HHMMSS.tar.gz.part01`
- `offline-machine-package-MEGA-YYYYMMDD-HHMMSS.tar.gz.partNN`...（多檔案，全部都要載）
- `offline-machine-package-MEGA-YYYYMMDD-HHMMSS.sha256`（校驗檔，也要載）

用瀏覽器 / curl / wget 都行。例：
```bash
curl -L -O https://github.com/<owner>/<repo>/releases/download/<tag>/offline-machine-package-MEGA-XXX.tar.gz
curl -L -O https://github.com/<owner>/<repo>/releases/download/<tag>/offline-machine-package-MEGA-XXX.sha256
```

### 2. 驗證（建議但非必須）

確認檔案沒下載壞：
```bash
sha256sum -c offline-machine-package-MEGA-XXX.sha256
# 應顯示 "OK"
```

Mac 用 `shasum -a 256 -c` 代替 `sha256sum -c`。

### 3. 送進公司

用你習慣的方式（隨身碟、跳板、檔案閘道）把**所有檔**（含 `.part` 全部 + `.sha256`）一起送到公司內網。

**完成。** 接手的同事自己會處理剩下的。

---

## 不會用到的東西

你**不需要**：
- 不需要 `git clone`
- 不需要裝任何工具（Python、Node、Docker 都不用）
- 不需要登入 GitHub
- 不需要懂 tarball 裡面是什麼

如果有人叫你「跑某個 script」、「執行 install」，請拒絕並回報。你的工作只到「送進公司」為止。

---

## FAQ

**Q: 檔案很大，下載失敗怎麼辦？**
A: 用 `curl -C -` 續傳：`curl -L -C - -O <url>`。或叫人重新切小一點再放上去。

**Q: 部份檔案下載完整、部份失敗怎辦？**
A: 只重抓失敗的那幾個（檔名一樣，重跑 `curl -L -O <url>` 會覆蓋）。

**Q: 送進公司的網路 / USB 有大小限制？**
A: 如果有，請告訴我，我會把檔案切更小再放上去。

**Q: 為什麼不直接 `git clone`？**
A: 因為裡面有 1 GB 等級的 binary 檔，git clone 不適合。Release 才適合放這種。

---

謝謝！
