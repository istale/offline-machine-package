# 從 Mac 產出離線 RHEL 8.10 tarball — Howto

從 Apple Silicon Mac 產出能在離線 RHEL 8.10（或 Rocky / Alma 8.10）機器直接安裝的
tarball。所有 binary wheel、native module、git history 都打包好，離線機只要
`tar xzf` + `dnf install` 即可。

> 本文件位置：`/Users/istale/Documents/pi-agent-obervation/docs/cross-os-offline-tarball-howto.md`
>
> 已驗證案例：AOH stack (4 個 repo) → RHEL 8.10，3.5 GB tarball，
> 311 個 cp312 x86_64 wheels 全為 manylinux_2_28 binary，0 污染、0 sdists。

---

## 1. 核心原則

| 維度 | 為什麼重要 |
|---|---|
| **glibc 版本一致** | RHEL 8.x = glibc 2.28。容器必須也是 glibc 2.28，否則整批 wheel 在離線機 `GLIBC_X.Y not found`。 |
| **arch 一致 (x86_64)** | M-series Mac 是 arm64，**必須** `--platform linux/amd64`，否則 Docker 拉 arm64 image，wheels 也跟著 arm64。 |
| **Python 3.x 的 manylinux tag** | pip 會自動選對 tag，**只要容器內的 glibc 版本對**。不需手動指定 `--platform manylinux_2_28_x86_64`。 |
| **Native build container 用 Rocky 8.10** | 別用 Ubuntu / Alpine — glibc 版本不對，wheel tag 對不上 RHEL。 |

---

## 2. 目標 OS → 容器 base image

| 目標離線機 | glibc | 推薦 base image | Python 3.12 | Node 22 |
|---|---|---|---|---|
| **RHEL 8.10** / Rocky 8.10 / Alma 8.10 | 2.28 | `rockylinux/rockylinux:8.10` | `dnf install python3.12` | NodeSource `setup_22.x` |

Rocky Linux 8.10 = RHEL 8.10 的 1:1 binary rebuild，wheels / RPM / glibc 完全相容。

---

## 3. 標準流程

### 3.1 前置（Mac host）

```sh
# OrbStack 或 Docker Desktop 任一即可
docker version
docker pull --platform linux/amd64 rockylinux/rockylinux:8.10
```

### 3.2 Wrapper script 模板

把下面存成你專案的 `scripts/offline-prep-in-docker.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# === 改這幾個 ===
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${TARGET_IMAGE:-rockylinux/rockylinux:8.10}"
PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
NODE_MAJOR="${NODE_MAJOR:-22}"
PY_VERSION="${PY_VERSION:-python3.12}"
INNER_SCRIPT="${INNER_SCRIPT:-./scripts/offline-prep.sh}"  # 真正做 pip download / npm cache 的 script
# ================

command -v docker >/dev/null || { echo "docker not found"; exit 1; }

INNER='set -euo pipefail
echo "[container] $(uname -m) $(. /etc/os-release; echo $PRETTY_NAME)"

dnf install -y --setopt=install_weak_deps=False --quiet \
    git tar gzip curl which findutils make gcc \
    '"$PY_VERSION"' '"$PY_VERSION"'-pip \
  >/tmp/dnf.log 2>&1 || { tail -40 /tmp/dnf.log; exit 1; }
'"$PY_VERSION"' -m pip install --quiet --upgrade pip wheel

curl -fsSL "https://rpm.nodesource.com/setup_'"$NODE_MAJOR"'.x" | bash - >/tmp/node.log 2>&1 \
  || { tail -30 /tmp/node.log; exit 1; }
dnf install -y --quiet nodejs >>/tmp/dnf.log 2>&1 \
  || { tail -40 /tmp/dnf.log; exit 1; }
corepack enable && corepack prepare pnpm@latest --activate

git config --global --add safe.directory "*"

cd /workspace
exec '"$INNER_SCRIPT"'
'

docker run --rm -i \
  --platform "$PLATFORM" \
  -v "$PROJECT_ROOT":/workspace \
  -w /workspace \
  "$IMAGE" \
  bash -c "$INNER"

echo "Done. Bundle should be in $PROJECT_ROOT/dist/"
```

### 3.3 你自己的 `offline-prep.sh` 大概長這樣

```bash
#!/usr/bin/env bash
# 容器內跑。所有 pip download / npm install 都產出 x86_64 + glibc 2.28 binary。
set -euo pipefail

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/vendor/python" "$STAGE/vendor/npm-cache" "$STAGE/repos"

# 1. git bundle —— history 帶走
for repo in repoA repoB; do
  (cd "$repo" && git bundle create "$STAGE/repos/$repo.bundle" HEAD --branches --tags)
done

# 2. Python wheels —— 容器內 pip 自動拿對 tag (glibc 2.28 → manylinux_2_28)
python3.12 -m pip download --dest "$STAGE/vendor/python" --quiet ./repoA[dev]

# 3. npm / pnpm cache
(cd repoA && npm install --cache "$STAGE/vendor/npm-cache/repoA" --prefer-offline --ignore-scripts)
(cd repoB && pnpm fetch --store-dir "$STAGE/vendor/pnpm-store")

# 4. 自己 build 出來的東西（dist/、frontend bundle、WASM 等）
# cp -R ...

mkdir -p dist
tar -C "$STAGE" -czf "dist/offline-bundle-$(date -u +%Y%m%d).tar.gz" .
```

### 3.4 跑 + 驗證

```sh
./scripts/offline-prep-in-docker.sh

BUNDLE=dist/offline-bundle-*.tar.gz

# (a) wheel tag 對嗎？應全 manylinux_2_28 / _2_17 / 2014（後兩者也相容 RHEL 8）
tar -tzf $BUNDLE | grep '\.whl$' | grep -v none-any | head -10

# (b) 沒被 arm64/macos 污染？應為空
tar -tzf $BUNDLE | grep '\.whl$' | grep -E '(arm64|aarch64|macosx|win_amd64|musllinux)'

# (c) 沒有 sdists（離線機要編譯就完蛋）
tar -tzf $BUNDLE | grep -c '\.tar\.gz$'   # 越接近 0 越好
```

### 3.5 離線機解開

```sh
mkdir ~/work && tar -C ~/work -xzf offline-bundle-XXXX.tar.gz
cd ~/work

# pip 一定要 --no-index --find-links，才不會去打 PyPI：
python3.12 -m pip install --no-index --find-links vendor/python ./repoA[dev]

# npm 同理：用 --cache + --offline
(cd repoA && npm install --cache ../vendor/npm-cache/repoA --offline)
```

---

## 4. 通用驗證 checklist

打包完跑這串，全綠才寄出去：

```sh
B=dist/your-bundle.tar.gz

# 1. wheel 全 x86_64（無污染）
tar -tzf $B | grep '\.whl$' | grep -E '(arm64|aarch64|macosx|win_amd64|musllinux)' \
  && echo '❌ 有污染' || echo '✅ 純 x86_64'

# 2. wheel tag 匹配 RHEL 8 (glibc 2.28) — 應只看到 manylinux_2_28 / _2_17 / 2014 / _2_5
tar -tzf $B | grep '\.whl$' | grep -v 'none-any' \
  | grep -oE 'manylinux[_0-9]+' | sort -u

# 3. Python ABI 一致（不要混 cp310 / cp311 / cp312）
tar -tzf $B | grep '\.whl$' | grep -oE 'cp3[0-9]+' | sort -u

# 4. sdists 越少越好
tar -tzf $B | grep -c '\.tar\.gz$'

# 5. git bundle 都在
tar -tzf $B | grep -E '\.bundle$'
```

---

## 5. 常見坑

| 症狀 | 原因 | 解 |
|---|---|---|
| `GLIBC_2.X not found` 在離線機 | 容器 base image glibc 太新（誤用 RHEL 9 image） | 改用 `rockylinux/rockylinux:8.10` |
| wheel 變成 arm64 | 忘了 `--platform linux/amd64` | docker run 加 flag |
| pip 在離線機去打 PyPI | 沒加 `--no-index --find-links` | 全部 install 都要 |
| Node native module (`better-sqlite3` 等) 在離線機編譯失敗 | npm cache 只有 source tarball，沒 prebuild | 容器內 `npm install` 跑完一次，把整個 `node_modules/` 帶走，別只帶 cache |
| Bind mount 檔案 owner 變 root | docker 預設 root 寫入 | OrbStack 通常自動 map；Docker Desktop 加 `-u $(id -u):$(id -g)` 或最後 `chown` |
| 容器內 `git rev-parse` 抱怨 `dubious ownership` | bind mount uid 不一致 | inner script 已含 `git config --global --add safe.directory "*"` |
| Docker Hub 找不到 `rockylinux:8.10` | `library/rockylinux` namespace 沒有 point version tag | 用 `rockylinux/rockylinux:8.10`（注意 namespace） |

---

## 6. 參考實作（AOH stack）

完整可跑的範本：

- `repos/pi-owui-bridge/scripts/aoh/offline-prep-in-docker.sh` — Docker wrapper
- `repos/pi-owui-bridge/scripts/aoh/offline-prep-all.sh` — 真正打包邏輯（4 repos 版）
- `repos/pi-owui-bridge/scripts/aoh/offline-unpack.sh` — 離線端解開
- `repos/pi-owui-bridge/scripts/aoh/install-all.sh` — 離線端 `AOH_OFFLINE=1` 安裝

已驗證輸出：`repos/dist/aoh-offline-bundle-20260619-193dbd9.tar.gz`
（3.5 GB、311 wheels、0 污染、0 sdists）
