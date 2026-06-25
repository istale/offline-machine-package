#!/usr/bin/env bash
# scripts/mac/sideload-skills.sh
# Bundle multiple agent-skills repos into one tarball for offline use.
# Each repo is shallow-cloned. Discovery on the target side is uniform:
# "anything with a SKILL.md is a skill."
#
# Also writes manifest.json listing every skill so install-skills.sh can
# present a picker without re-scanning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$ROOT/workspace/skills-stage"

# Default skill repos. Override with SKILL_REPOS env (space-separated).
DEFAULT_REPOS=(
  "nashsu/llm_wiki_skill"
  "addyosmani/agent-skills"
  "bergside/awesome-design-skills"
  "awesome-skills/code-review-skill"
)
read -r -a REPOS <<< "${SKILL_REPOS:-${DEFAULT_REPOS[*]}}"

mkdir -p "$OUT_DIR"
rm -rf "$WORK"; mkdir -p "$WORK/repos"

for repo in "${REPOS[@]}"; do
  name=$(basename "$repo")
  echo "[skills] cloning $repo"
  gh repo clone "$repo" "$WORK/repos/$name" -- --depth=1 2>&1 | tail -1
  COMMIT=$(git -C "$WORK/repos/$name" rev-parse HEAD)
  rm -rf "$WORK/repos/$name/.git"
  echo "  → $COMMIT"
done

# Discover skills: any directory containing SKILL.md.
# The "skill id" is "<repo>/<relpath>" so duplicates across repos stay distinct.
echo "[skills] indexing skills"
MANIFEST="$WORK/manifest.json"
{
  echo "{"
  echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"skills\": ["
  first=1
  while IFS= read -r skillmd; do
    dir=$(dirname "$skillmd")
    rel=${dir#$WORK/repos/}
    repo=${rel%%/*}
    sub=${rel#$repo}
    sub=${sub#/}
    [[ -z "$sub" ]] && skillname="$repo" || skillname=$(basename "$sub")
    desc=$(awk '/^description:/{sub(/^description: */,""); gsub(/"/,""); print; exit}' "$skillmd" 2>/dev/null \
           || head -3 "$skillmd" | tr '\n' ' ' | cut -c1-80)
    desc=${desc:-<no description>}
    [[ $first -eq 1 ]] || echo ","
    printf '    {"id": "%s", "name": "%s", "repo": "%s", "path": "%s", "description": %s}' \
      "$rel" "$skillname" "$repo" "$rel" "$(printf '%s' "$desc" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
    first=0
  done < <(find "$WORK/repos" -name SKILL.md -type f | sort)
  echo
  echo "  ]"
  echo "}"
} > "$MANIFEST"

count=$(grep -c '"id":' "$MANIFEST" || echo 0)
echo "[skills] indexed $count skill(s)"

OUT="$OUT_DIR/skills-bundle-${STAMP}.tar.gz"
tar --owner=0 --group=0 -C "$WORK" -czf "$OUT" repos manifest.json
( cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" > "${OUT%.tar.gz}.sha256" )

echo
echo "[skills] ✅ produced:"
ls -lh "$OUT" "${OUT%.tar.gz}.sha256"
echo
echo "Skills indexed:"
grep -E '"name":|"repo":' "$MANIFEST" | paste - - | sed 's/^/  /'
echo
echo "Next: gh release upload v20260621 $OUT ${OUT%.tar.gz}.sha256 --clobber"
