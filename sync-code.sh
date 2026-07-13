#!/usr/bin/env bash
# Mirror the Mac's ~/Code layout onto the devbox: clone every git repo at the
# same relative path, then copy untracked .env* secrets into the clones.
# Run from the Mac. Requires `gh auth login` done ON the devbox first (clones
# use HTTPS + gh credential helper there). Idempotent: existing clones and
# existing remote .env files are left untouched.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
CODE_ROOT="${1:-$HOME/Code}"
# Paths (relative to CODE_ROOT) to skip entirely — workspaces of third-party
# clones, scratch dirs, anything not worth mirroring.
EXCLUDE_RE="${SYNC_EXCLUDE_RE:-security_researcher}"

manifest=$(mktemp); envlist=$(mktemp)
trap 'rm -f "$manifest" "$envlist"' EXIT

echo "== discovering git repos under $CODE_ROOT =="
find "$CODE_ROOT" -maxdepth 7 \
    \( -name node_modules -o -name .venv -o -name venv -o -name target -o -name .next \) -prune \
    -o -name .git \( -type d -o -type f \) -print 2>/dev/null \
  | while read -r g; do
      d=$(dirname "$g"); rel=${d#"$CODE_ROOT/"}
      echo "$rel" | grep -Eq "$EXCLUDE_RE" && continue
      url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
      # normalize to https so the devbox's gh credential helper handles auth
      https=$(echo "$url" | sed -e 's|^git@github.com:|https://github.com/|' -e 's|\.git$||')
      echo "$rel|$https.git"
    done | sort -u > "$manifest"
echo "  $(wc -l < "$manifest" | tr -d ' ') repos found"

echo "== cloning on $DEVBOX_NAME (existing clones skipped) =="
# Remote script is the ssh argument; the manifest rides on stdin.
ssh "mert@$DEVBOX_NAME" 'bash -c '\''
  while IFS="|" read -r rel url; do
    [ -z "$rel" ] && continue
    if [ -d "$HOME/Code/$rel/.git" ]; then echo "SKIP $rel"; continue; fi
    mkdir -p "$HOME/Code/$(dirname "$rel")"
    if git clone -q "$url" "$HOME/Code/$rel" 2>/dev/null; then echo "OK   $rel"
    else echo "FAIL $rel <- $url"; fi
  done
'\''' < "$manifest"

echo "== syncing .env files (never overwrites, skips untracked dirs) =="
find "$CODE_ROOT" -maxdepth 7 \
    \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name target -o -name .next \) -prune \
    -o -type f -name ".env*" -print 2>/dev/null \
  | sed "s|^$CODE_ROOT/||" | grep -Ev "$EXCLUDE_RE" > "$envlist" || true
echo "  $(wc -l < "$envlist" | tr -d ' ') env files found"

# Stage 1: ship the tarball (stdin = tar stream).
# COPYFILE_DISABLE stops macOS bsdtar from shipping AppleDouble (._*) junk.
COPYFILE_DISABLE=1 tar czf - -C "$CODE_ROOT" -T "$envlist" | ssh "mert@$DEVBOX_NAME" \
  'bash -c "rm -rf ~/.env-staging && mkdir -p ~/.env-staging && tar xzf - -C ~/.env-staging"'

# Stage 2: place files (separate connection; no stdin contention).
ssh "mert@$DEVBOX_NAME" 'bash -c '\''
  cd ~/.env-staging || exit 0
  find . -type f -name "._*" -delete
  find . -type f | sed "s|^\./||" | sort | while read -r rel; do
    tgt="$HOME/Code/$rel"
    if [ ! -d "$(dirname "$tgt")" ]; then echo "SKIP no-dir  $rel"
    elif [ -e "$tgt" ]; then echo "SKIP exists  $rel"
    else cp "$rel" "$tgt" && chmod 600 "$tgt" && echo "COPIED       $rel"; fi
  done
  cd / && rm -rf ~/.env-staging
'\'''
echo "done."
