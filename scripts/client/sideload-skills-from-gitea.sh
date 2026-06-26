#!/usr/bin/env bash
# scripts/client/sideload-skills-from-gitea.sh
# Internal-network twin of scripts/mac/sideload-skills.sh.
#
# Runs ON the offline side (or any machine with HTTP access to Gitea). Clones
# the skill repos directly from your in-house Gitea mirror, then produces the
# same skills-bundle-*.tar.gz format that install-skills.sh consumes. No
# GitHub, no `gh` CLI, no Mac middleman needed once your Gitea is populated.
#
# Prereq (one-time): mirror these repos into Gitea. Easiest way is Gitea's
# built-in "Migrate Repository" UI (set as "Mirror" so it keeps tracking
# upstream), or via API:
#   curl -u USER:TOKEN -X POST http://gitea.internal/api/v1/repos/migrate \
#     -H "Content-Type: application/json" -d '{
#       "clone_addr":"https://github.com/nashsu/llm_wiki_skill.git",
#       "repo_owner":"skills-mirror","repo_name":"llm_wiki_skill","mirror":true
#     }'
#
# Usage:
#   GITEA_BASE=http://gitea.internal/skills-mirror \
#     sideload-skills-from-gitea.sh
#
#   # Or per-repo override (if your Gitea layout doesn't preserve owner/name):
#   SKILL_REPOS="llm_wiki_skill agent-skills awesome-design-skills" \
#     GITEA_BASE=http://gitea.internal/skills-mirror \
#     sideload-skills-from-gitea.sh
#
# Output: ./skills-bundle-<stamp>.tar.gz + .sha256 in $OUT_DIR (cwd default).
set -euo pipefail

GITEA_BASE="${GITEA_BASE:?set GITEA_BASE, e.g. http://gitea.internal/skills-mirror}"
OUT_DIR="${OUT_DIR:-$PWD}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="${WORK:-$(mktemp -d -t skills-stage.XXXXXX)}"

# Default skill repo names (no owner prefix; final URL = $GITEA_BASE/<name>.git).
# Override with SKILL_REPOS env, space-separated.
DEFAULT_REPOS=(
  "llm_wiki_skill"
  "agent-skills"
  "awesome-design-skills"
  "code-review-skill"
  "ui-ux-pro-max-skill"
)
read -r -a REPOS <<< "${SKILL_REPOS:-${DEFAULT_REPOS[*]}}"

# Optional auth — for private mirrors. Leave unset for public.
AUTH_CURL=()
[[ -n "${GITEA_USER:-}" && -n "${GITEA_TOKEN:-}" ]] && \
  AUTH_OPT="-c credential.helper=!f(){ echo username=$GITEA_USER; echo password=$GITEA_TOKEN; };f" || \
  AUTH_OPT=""

mkdir -p "$OUT_DIR" "$WORK/repos"

for name in "${REPOS[@]}"; do
  url="$GITEA_BASE/$name.git"
  echo "[skills-gitea] cloning $url"
  if [[ -n "$AUTH_OPT" ]]; then
    git $AUTH_OPT clone --depth=1 "$url" "$WORK/repos/$name" 2>&1 | tail -1
  else
    git clone --depth=1 "$url" "$WORK/repos/$name" 2>&1 | tail -1
  fi
  COMMIT=$(git -C "$WORK/repos/$name" rev-parse HEAD)
  rm -rf "$WORK/repos/$name/.git"
  echo "  → $COMMIT"
done

# Same discovery + manifest format as the Mac script — install-skills.sh
# treats both outputs identically.
echo "[skills-gitea] indexing skills"
MANIFEST="$WORK/manifest.json"
{
  echo "{"
  echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"source\": \"gitea\","
  echo "  \"gitea_base\": \"$GITEA_BASE\","
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
      "$rel" "$skillname" "$repo" "$rel" \
      "$(printf '%s' "$desc" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
    first=0
  done < <(find "$WORK/repos" -name SKILL.md -type f \
              -not -path '*/cli/assets/*' \
              -not -path '*/preview/*' \
              -not -path '*/node_modules/*' \
              -not -path '*/test/*' \
              -not -path '*/tests/*' | sort)
  echo
  echo "  ]"
  echo "}"
} > "$MANIFEST"

count=$(grep -c '"id":' "$MANIFEST" || echo 0)
echo "[skills-gitea] indexed $count skill(s)"

OUT="$OUT_DIR/skills-bundle-${STAMP}.tar.gz"
tar --owner=0 --group=0 -C "$WORK" -czf "$OUT" repos manifest.json
( cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" > "${OUT%.tar.gz}.sha256" )
rm -rf "$WORK"

echo
echo "[skills-gitea] ✅ produced:"
ls -lh "$OUT" "${OUT%.tar.gz}.sha256"
echo
echo "Next:"
echo "  bash install-skills.sh $OUT --list"
echo "  bash install-skills.sh $OUT     # interactive picker"
