#!/usr/bin/env bash
# scripts/client/install-skills.sh
# Browse + install agent skills from a skills-bundle-*.tar.gz onto an
# offline RHEL host. No root needed. Works per-user; paths are configurable.
#
# Usage:
#   install-skills.sh <bundle.tar.gz>                # interactive picker
#   install-skills.sh <bundle.tar.gz> --list         # show skills, exit
#   install-skills.sh <bundle.tar.gz> --all          # install everything
#   install-skills.sh <bundle.tar.gz> --skill ID...  # install named skills
#   install-skills.sh <bundle.tar.gz> --target DIR   # override target
#   install-skills.sh <bundle.tar.gz> --copy         # copy (default: symlink)
#
# Default target: $HOME/.claude/skills (Claude Code convention). Override
# with --target or env SKILLS_TARGET — every offline host's layout differs.
# Source files live in SKILLS_HOME (default: $HOME/.local/share/skills-src);
# symlinks point there so you can re-target without re-extracting.
set -euo pipefail

BUNDLE=""
LIST_ONLY=0; INSTALL_ALL=0; COPY=0
declare -a WANTED=()
TARGET="${SKILLS_TARGET:-$HOME/.claude/skills}"
SRC_HOME="${SKILLS_HOME:-$HOME/.local/share/skills-src}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)   LIST_ONLY=1; shift ;;
    --all)    INSTALL_ALL=1; shift ;;
    --skill)  shift; while [[ $# -gt 0 && "$1" != --* ]]; do WANTED+=("$1"); shift; done ;;
    --target) TARGET="$2"; shift 2 ;;
    --src)    SRC_HOME="$2"; shift 2 ;;
    --copy)   COPY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)        [[ -z "$BUNDLE" ]] && BUNDLE="$1" || { echo "unknown arg: $1"; exit 2; }; shift ;;
  esac
done
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "usage: $0 <bundle.tar.gz> [opts]"; exit 2; }

# 1. extract once into SRC_HOME so symlinks remain valid after script exits
mkdir -p "$SRC_HOME"
echo "[skills] extracting bundle → $SRC_HOME"
tar -xzf "$BUNDLE" -C "$SRC_HOME"
MANIFEST="$SRC_HOME/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "[skills] missing manifest.json in bundle"; exit 1; }

# 2. parse manifest with python3 (always present on RHEL 8.10)
python3 - "$MANIFEST" > "$SRC_HOME/.skills.tsv" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for s in m["skills"]:
    print("\t".join([s["id"], s["name"], s["repo"], s.get("description","")[:70]]))
PY

count=$(wc -l < "$SRC_HOME/.skills.tsv")
echo "[skills] found $count skill(s) in bundle"
echo

print_table() {
  local i=1
  printf "%3s  %-40s  %-30s  %s\n" "#" "ID" "REPO" "DESCRIPTION"
  printf "%3s  %-40s  %-30s  %s\n" "---" "----------------------------------------" \
                                  "------------------------------" "-----------"
  while IFS=$'\t' read -r id name repo desc; do
    printf "%3d  %-40s  %-30s  %s\n" "$i" "${id:0:40}" "${repo:0:30}" "${desc:0:60}"
    i=$((i+1))
  done < "$SRC_HOME/.skills.tsv"
}

if [[ $LIST_ONLY -eq 1 ]]; then
  print_table
  exit 0
fi

# 3. select skills
declare -a SELECTED_IDS=()
if [[ $INSTALL_ALL -eq 1 ]]; then
  while IFS=$'\t' read -r id _ _ _; do SELECTED_IDS+=("$id"); done < "$SRC_HOME/.skills.tsv"
elif [[ ${#WANTED[@]} -gt 0 ]]; then
  for w in "${WANTED[@]}"; do
    if grep -qE "^${w}	|	${w}	" "$SRC_HOME/.skills.tsv"; then
      # match by id OR name
      hit=$(awk -F'\t' -v w="$w" '$1==w || $2==w {print $1; exit}' "$SRC_HOME/.skills.tsv")
      SELECTED_IDS+=("$hit")
    else
      echo "[skills] WARN: no skill matches '$w'"
    fi
  done
else
  # interactive
  print_table
  echo
  echo "Pick skills to install. Enter numbers separated by spaces or commas."
  echo "Examples:  1 3 5    or    1,3,5    or    all    or    q to quit"
  read -r -p "> " input
  [[ "$input" =~ ^[Qq] ]] && { echo "[skills] cancelled"; exit 0; }
  if [[ "$input" == "all" ]]; then
    while IFS=$'\t' read -r id _ _ _; do SELECTED_IDS+=("$id"); done < "$SRC_HOME/.skills.tsv"
  else
    # normalize: commas → spaces
    input=${input//,/ }
    for n in $input; do
      [[ "$n" =~ ^[0-9]+$ ]] || { echo "[skills] skipping '$n' (not a number)"; continue; }
      id=$(awk -F'\t' -v n="$n" 'NR==n {print $1}' "$SRC_HOME/.skills.tsv")
      [[ -n "$id" ]] && SELECTED_IDS+=("$id") || echo "[skills] no skill #$n"
    done
  fi
fi

[[ ${#SELECTED_IDS[@]} -gt 0 ]] || { echo "[skills] nothing selected"; exit 0; }

# 4. confirm target
echo
echo "[skills] target directory: $TARGET"
echo "[skills] selected ${#SELECTED_IDS[@]} skill(s):"
printf "  - %s\n" "${SELECTED_IDS[@]}"
if [[ -z "${SKILLS_YES:-}" && -t 0 ]]; then
  read -r -p "Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "cancelled"; exit 0; }
fi

mkdir -p "$TARGET"

# 5. install
for id in "${SELECTED_IDS[@]}"; do
  src="$SRC_HOME/repos/$id"
  if [[ ! -d "$src" ]]; then
    echo "[skills] ✗ source missing: $src (manifest stale?)"
    continue
  fi
  # destination dir name = skill's leaf (name field)
  leaf=$(awk -F'\t' -v id="$id" '$1==id {print $2; exit}' "$SRC_HOME/.skills.tsv")
  dst="$TARGET/$leaf"
  if [[ -e "$dst" || -L "$dst" ]]; then
    backup="$dst.bak.$(date -u +%Y%m%d%H%M%S)"
    echo "[skills] backing up existing $dst → $backup"
    mv "$dst" "$backup"
  fi
  if [[ $COPY -eq 1 ]]; then
    cp -a "$src" "$dst"
    echo "[skills] ✓ copied   $id → $dst"
  else
    ln -s "$src" "$dst"
    echo "[skills] ✓ linked   $id → $dst"
  fi
done

echo
echo "[skills] ✅ installed ${#SELECTED_IDS[@]} skill(s) to $TARGET"
echo "[skills] source kept at: $SRC_HOME"
echo "[skills] re-target later: install-skills.sh <bundle> --target /new/path --skill <id>..."
