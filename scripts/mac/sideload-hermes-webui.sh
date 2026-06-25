#!/usr/bin/env bash
# scripts/mac/sideload-hermes-webui.sh
# Package nesquena/hermes-webui for offline RHEL 8.10. Lightweight:
#   - pure Python 3.12 + 2 pip deps (pyyaml, cryptography)
#   - vanilla JS frontend, NO npm build step
# So we just ship: source tarball + pip wheels. No 5-path restore, no root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
REPO="${WEBUI_REPO:-nesquena/hermes-webui}"
REF="${WEBUI_REF:-master}"
PLATFORM="linux/amd64"
PY_IMAGE="python:3.12-slim"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$ROOT/workspace/hermes-webui-stage"

mkdir -p "$OUT_DIR"
rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/wheels"

echo "[webui] fetching source $REPO@$REF"
( cd "$WORK" && gh repo clone "$REPO" src -- --depth=1 --branch "$REF" )
COMMIT=$(git -C "$WORK/src" rev-parse HEAD)
rm -rf "$WORK/src/.git"

echo "[webui] downloading pip wheels (linux x86_64, cp312)"
docker run --rm --platform "$PLATFORM" \
  -v "$WORK/wheels":/wheels \
  -v "$WORK/src/requirements.txt":/req.txt:ro \
  "$PY_IMAGE" \
  pip download -d /wheels -r /req.txt \
    --platform manylinux2014_x86_64 --python-version 3.12 \
    --only-binary=:all: --no-deps 2>&1 | tail -20

# pyyaml + cryptography pull transitive deps (cffi, pycparser). Re-run with deps.
docker run --rm --platform "$PLATFORM" \
  -v "$WORK/wheels":/wheels \
  -v "$WORK/src/requirements.txt":/req.txt:ro \
  "$PY_IMAGE" \
  pip download -d /wheels -r /req.txt \
    --platform manylinux2014_x86_64 --python-version 3.12 \
    --only-binary=:all: 2>&1 | tail -5

cat > "$WORK/BUILD_INFO" <<EOF
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo=$REPO
ref=$REF
commit=$COMMIT
wheels=$(ls "$WORK/wheels" | wc -l | tr -d ' ')
EOF

cat > "$WORK/INSTALL.md" <<'EOF'
# hermes-webui offline install

No root needed. Runs as any user. Assumes Python 3.12 already on host
(from Enterprise OSS dnf, or the python3.12 RPM bundled elsewhere).

```bash
tar xzf hermes-webui-bundle-*.tar.gz
cd hermes-webui
python3.12 -m venv .venv
.venv/bin/pip install --no-index --find-links ../wheels -r requirements.txt
# point at your hermes-agent install if needed
bash start.sh
```

The webui talks to a running hermes-agent over HTTP/IPC. Install hermes-agent
separately via install-hermes.sh (or pip install hermes-agent from Nexus).
EOF

OUT="$OUT_DIR/hermes-webui-bundle-${STAMP}.tar.gz"
echo "[webui] packing → $OUT"
tar --owner=0 --group=0 -C "$WORK" -czf "$OUT" .
( cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" > "${OUT%.tar.gz}.sha256" )

echo "[webui] ✅ produced:"
ls -lh "$OUT" "${OUT%.tar.gz}.sha256"
cat "$WORK/BUILD_INFO"
echo
echo "Next: gh release upload <tag> $OUT ${OUT%.tar.gz}.sha256 --clobber"
