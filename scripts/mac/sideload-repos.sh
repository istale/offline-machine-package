#!/usr/bin/env bash
# scripts/mac/sideload-repos.sh
# Reads manifests/repos.txt (lines: <upstream-url> <gitea-owner/name>),
# git clone --mirror into workspace/repos/, then produces a tarball of
# git bundles + a manifest the hub side reads to push into Gitea.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/manifests/repos.txt}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
WS="$ROOT/workspace/repos"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST"; exit 1; }
mkdir -p "$OUT_DIR" "$WS"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/bundles"
: > "$STAGE/repos.manifest"

while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  url=$(awk '{print $1}' <<< "$line")
  dst=$(awk '{print $2}' <<< "$line")
  [[ -n "$url" && -n "$dst" ]] || { echo "bad line: $line"; exit 1; }

  safe=$(echo "$dst" | tr '/' '_')
  mirror="$WS/${safe}.git"

  if [[ -d "$mirror" ]]; then
    echo "[repos] update $url -> $mirror"
    git -C "$mirror" remote update --prune
  else
    echo "[repos] mirror $url -> $mirror"
    git clone --mirror "$url" "$mirror"
  fi

  bundle="$STAGE/bundles/${safe}.bundle"
  echo "[repos] bundle $bundle"
  git -C "$mirror" bundle create "$bundle" --all
  echo "$safe $dst" >> "$STAGE/repos.manifest"
done < "$MANIFEST"

OUT="$OUT_DIR/repos-bundle-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$STAGE" -czf "$OUT" .
echo "[repos] produced: $OUT"
echo "[repos] manifest (safe-name -> gitea-target):"
cat "$STAGE/repos.manifest"
