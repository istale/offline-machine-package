#!/usr/bin/env bash
# scripts/client/build-node-project.sh
# Build a Node.js project on an offline RHEL host using the Nexus npm registry.
# Pure wrapper around `npm ci` — does not execute remote build scripts itself;
# whatever runs is whatever the project's own package.json declares.
#
# Usage:
#   build-node-project.sh <project-dir>
#
# Env overrides:
#   NPM_REGISTRY  Nexus npm group URL (default: http://nexus.internal:8081/repository/npm-group/)
#   NPM_CACHE     local cache dir (default: /var/tmp/$USER-npmcache, off-NFS)
#   SKIP_BUILD=1  install deps only, skip `npm run build`
#
# ----------------------------------------------------------------------
# Example: build + run llm-wiki MCP server on an offline RHEL host
# ----------------------------------------------------------------------
# Source tarball comes from the offline-machine-package GitHub release
# (asset: llm-wiki-src-v0.5.2.tar.gz). Helper delivers it; no internet needed
# on the target — npm deps come from your in-house Nexus.
#
#   # 1. unpack the upstream source the helper brought in
#   mkdir -p ~/llm-wiki && tar xzf llm-wiki-src-v0.5.2.tar.gz -C ~/llm-wiki
#
#   # 2. install deps + tsc build via Nexus npm-group
#   NPM_REGISTRY=http://nexus.internal:8081/repository/npm-group/ \
#     bash build-node-project.sh ~/llm-wiki/mcp-server
#
#   # 3. run the MCP server (Node >= 20; RHEL 8.10 has v22/v24 from OSS)
#   node ~/llm-wiki/mcp-server/dist/src/index.js
#
#   # 4. wire it into your agent's MCP config, e.g.:
#   #   { "mcpServers": { "llm-wiki": {
#   #       "command": "node",
#   #       "args": ["/home/<user>/llm-wiki/mcp-server/dist/src/index.js"] } } }
# ----------------------------------------------------------------------
set -euo pipefail

DIR="${1:?usage: $0 <project-dir>}"
[[ -d "$DIR" ]] || { echo "[build-node] not a directory: $DIR"; exit 1; }
[[ -f "$DIR/package.json" ]] || { echo "[build-node] no package.json in $DIR"; exit 1; }

NPM_REGISTRY="${NPM_REGISTRY:-http://nexus.internal:8081/repository/npm-group/}"
NPM_CACHE="${NPM_CACHE:-/var/tmp/$USER-npmcache}"
mkdir -p "$NPM_CACHE"

command -v node >/dev/null || { echo "[build-node] node not found in PATH"; exit 1; }
command -v npm  >/dev/null || { echo "[build-node] npm not found in PATH"; exit 1; }

echo "[build-node] node $(node -v)  npm $(npm -v)"
echo "[build-node] registry: $NPM_REGISTRY"
echo "[build-node] cache:    $NPM_CACHE"
echo "[build-node] project:  $DIR"

cd "$DIR"

if [[ ! -f package-lock.json ]]; then
  echo "[build-node] WARNING: no package-lock.json — using 'npm install' instead of 'npm ci'."
  echo "[build-node]          Versions will be resolved at install time; may pull from Nexus"
  echo "[build-node]          packages not yet mirrored. Prefer committing a lockfile."
  CMD=install
else
  CMD=ci
fi

npm "$CMD" \
  --registry="$NPM_REGISTRY" \
  --cache="$NPM_CACHE" \
  --no-audit --no-fund

if [[ "${SKIP_BUILD:-}" == "1" ]]; then
  echo "[build-node] SKIP_BUILD=1 — deps installed, skipping build."
  exit 0
fi

# Only run build if the project declares one. Avoids confusing errors on
# library packages that have no build step.
if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)" 2>/dev/null; then
  echo "[build-node] running 'npm run build'"
  npm run build
else
  echo "[build-node] no build script declared; install-only."
fi

echo "[build-node] ✅ done: $DIR"
