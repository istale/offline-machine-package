#!/usr/bin/env bash
# scripts/hub/upload-repos.sh
# Read repos.manifest inside the bundle and push each git bundle into Gitea.
# Creates the target repo via Gitea API if missing.
set -euo pipefail
: "${GITEA_BASE:?export GITEA_BASE  (e.g. http://gitea.internal:3000)}"
: "${GITEA_TOKEN:?export GITEA_TOKEN}"
TARBALL="${1:?usage: $0 <repos-bundle-*.tar.gz>}"

STAGE="$(mktemp -d)"; trap "rm -rf $STAGE" EXIT
tar -C "$STAGE" -xzf "$TARBALL"

while read -r safe target; do
  owner="${target%%/*}"; name="${target##*/}"
  bundle="$STAGE/bundles/${safe}.bundle"
  [[ -f "$bundle" ]] || { echo "missing $bundle"; exit 1; }

  # Ensure owner org exists (ignore failure if already there or it's a user)
  curl -sf -X POST -H "Authorization: token $GITEA_TOKEN" \
    -H 'Content-Type: application/json' \
    "$GITEA_BASE/api/v1/orgs" -d "{\"username\":\"$owner\"}" >/dev/null 2>&1 || true

  # Create repo (ignore 409 already exists)
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: token $GITEA_TOKEN" \
    -H 'Content-Type: application/json' \
    "$GITEA_BASE/api/v1/orgs/$owner/repos" \
    -d "{\"name\":\"$name\",\"default_branch\":\"main\",\"auto_init\":false}")
  case "$code" in 201|409) ;; *) echo "create $target failed: $code"; exit 1 ;; esac

  # Clone from bundle into a temp working repo, then push everything to gitea
  work="$STAGE/work-${safe}"
  git clone --mirror "$bundle" "$work"
  remote="${GITEA_BASE/http:\/\//http://token:${GITEA_TOKEN}@}/$owner/$name.git"
  git -C "$work" remote set-url origin "$remote"
  git -C "$work" push --mirror
  echo "[repos] pushed $target"
done < "$STAGE/repos.manifest"
