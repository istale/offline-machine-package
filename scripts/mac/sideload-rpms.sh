#!/usr/bin/env bash
# scripts/mac/sideload-rpms.sh
# Reads manifests/rpms.txt. Downloads RPMs inside Rocky 8.10 container or
# collects local file:./path entries. Produces dist/rpms-bundle-*.tar.gz.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/rpms.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
PLATFORM="linux/amd64"
IMAGE="rockylinux/rockylinux:8.10"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"; mkdir -p "$STAGE/rpm"

REMOTE=() ; LOCAL=()
while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  if [[ "$line" == file:* ]]; then LOCAL+=("${line#file:}"); else REMOTE+=("$line"); fi
done < "$MANIFEST"

for f in "${LOCAL[@]:-}"; do [[ -n "$f" ]] || continue; cp "$ROOT/$f" "$STAGE/rpm/"; done

if [[ ${#REMOTE[@]} -gt 0 ]]; then
  echo "[rpms] downloading: ${REMOTE[*]}"
  docker run --rm --platform "$PLATFORM" -v "$STAGE/rpm":/out "$IMAGE" \
    bash -c "dnf install -y --quiet --downloadonly --downloaddir=/out ${REMOTE[*]}"
fi

ls "$STAGE/rpm" | grep -q . || { echo "nothing collected"; exit 0; }
OUT="$OUT_DIR/rpms-bundle-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo "[rpms] produced: $OUT"
