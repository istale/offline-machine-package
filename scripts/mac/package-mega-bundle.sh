#!/usr/bin/env bash
# scripts/mac/package-mega-bundle.sh
# Build a single "mega-bundle" tarball containing:
#   1. the repo source (manifests, scripts, docs, templates, etc.)
#   2. every dist/*.tar.gz produced by sideload-*.sh
# Designed for a non-technical helper who only needs to download ONE file from
# a GitHub Release and ship it to the offline site.
#
# If the result is > MAX_PART_SIZE (default 1800 MB, GitHub release asset
# limit is 2 GB), it is auto-split into .part00, .part01, ...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
MAX_PART_SIZE="${MAX_PART_SIZE:-1800m}"   # 1800 MiB; tweak via env

STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="offline-machine-package-MEGA-${STAMP}"
STAGE="$(mktemp -d)"
trap "rm -rf $STAGE" EXIT

echo "[mega] staging repo source"
# Use git to enumerate tracked files so we don't ship dist/ inside itself,
# but fall back to a manual copy if not yet a git repo.
mkdir -p "$STAGE/$NAME/repo"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # ls-files includes tracked, --others --exclude-standard adds new files
  ( cd "$ROOT" && git ls-files -co --exclude-standard ) | \
    while read -r f; do
      mkdir -p "$STAGE/$NAME/repo/$(dirname "$f")"
      cp -a "$ROOT/$f" "$STAGE/$NAME/repo/$f"
    done
else
  rsync -a --exclude='dist/' --exclude='workspace/' --exclude='.git/' \
        "$ROOT/" "$STAGE/$NAME/repo/"
fi

echo "[mega] staging dist/*.tar.gz"
mkdir -p "$STAGE/$NAME/dist"
shopt -s nullglob
DIST_FILES=("$OUT_DIR"/*.tar.gz)
if [[ ${#DIST_FILES[@]} -eq 0 ]]; then
  echo "[mega] ⚠ dist/ is empty — run scripts/mac/sideload-all.sh first"
fi
for f in "${DIST_FILES[@]}"; do
  case "$(basename "$f")" in
    offline-machine-package-MEGA-*.tar.gz|offline-machine-package-MEGA-*.part*)
      continue ;;  # don't include previous mega-bundles
  esac
  echo "  + $(basename "$f")"
  cp "$f" "$STAGE/$NAME/dist/"
done

# Manifest of what's inside, for the helper / hub-side verification
{
  echo "name=$NAME"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "built_on=$(uname -a)"
  ( cd "$ROOT" && git rev-parse HEAD 2>/dev/null && echo "git_status=$(git status --porcelain | wc -l | tr -d ' ') files dirty" ) || true
  echo
  echo "[bundles]"
  ( cd "$STAGE/$NAME/dist" && shasum -a 256 *.tar.gz 2>/dev/null || true )
} > "$STAGE/$NAME/MANIFEST.txt"
cp "$ROOT/HELPER.md" "$STAGE/$NAME/HELPER.md" 2>/dev/null || true

OUT_RAW="$OUT_DIR/$NAME.tar.gz"
echo "[mega] packing → $OUT_RAW"
tar -C "$STAGE" -czf "$OUT_RAW" "$NAME"

# Split if needed
SIZE_BYTES=$(stat -f%z "$OUT_RAW" 2>/dev/null || stat -c%s "$OUT_RAW")
SIZE_MB=$(( SIZE_BYTES / 1048576 ))
MAX_MB="${MAX_PART_SIZE%m}"
echo "[mega] size: ${SIZE_MB} MiB (limit ${MAX_MB} MiB)"

ASSETS=("$OUT_RAW")
if (( SIZE_MB > MAX_MB )); then
  echo "[mega] splitting into ${MAX_PART_SIZE} parts"
  split -b "$MAX_PART_SIZE" "$OUT_RAW" "${OUT_RAW}.part"
  rm "$OUT_RAW"
  ASSETS=( "$OUT_DIR/$NAME.tar.gz.part"* )
  # checksums for the helper to verify
  ( cd "$OUT_DIR" && shasum -a 256 "$NAME.tar.gz.part"* ) > "$OUT_DIR/$NAME.sha256"
  ASSETS+=( "$OUT_DIR/$NAME.sha256" )
else
  ( cd "$OUT_DIR" && shasum -a 256 "$NAME.tar.gz" ) > "$OUT_DIR/$NAME.sha256"
  ASSETS+=( "$OUT_DIR/$NAME.sha256" )
fi

echo
echo "[mega] ✅ assets ready in $OUT_DIR:"
for a in "${ASSETS[@]}"; do
  ls -lh "$a"
done

cat <<EOF

Next step — publish to GitHub Releases (helper only needs the URLs from here):

  gh release create v${STAMP} \\
$(printf '    %s \\\n' "${ASSETS[@]}")    --title "Offline package $STAMP" \\
    --notes-file HELPER.md

(Replace v${STAMP} with whatever tag you want.)
EOF
