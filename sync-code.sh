#!/usr/bin/env bash
# Mirror the Mac's ~/Code layout onto the devbox: clone every GitHub-hosted repo
# at the same relative path, then copy .env* files into clones that don't have
# them. Run from the Mac. Requires `gh auth login` done ON the devbox first
# (clones use HTTPS + gh credential helper there; non-GitHub remotes are
# skipped — the box has no SSH keys by design). Idempotent: existing clones and
# existing remote .env files are left untouched. Nested repos (submodules,
# vendored checkouts) are skipped — they're the parent repo's business.
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./secrets.env ] || { echo "secrets.env not found — cp secrets.env.example secrets.env and fill it in." >&2; exit 1; }
# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
DEV_USER="${DEV_USER:-dev}"
CODE_ROOT="${1:-$HOME/Code}"
CODE_ROOT="${CODE_ROOT%/}"   # a trailing slash would break every prefix-strip below
[ -d "$CODE_ROOT" ] || { echo "CODE_ROOT '$CODE_ROOT' is not a directory." >&2; exit 1; }
# Optional regex of paths (relative to CODE_ROOT) to skip entirely — workspaces
# of third-party clones, scratch dirs, anything not worth mirroring. Empty =
# exclude nothing (an empty regex must never reach grep: it matches everything).
EXCLUDE_RE="${SYNC_EXCLUDE_RE:-}"
# Validate it once: a malformed regex would otherwise fail open on repo
# exclusion but fail closed (sync nothing) on the env-file list.
if [ -n "$EXCLUDE_RE" ]; then
  if ! echo x | { grep -Eq "$EXCLUDE_RE"; [ $? -le 1 ]; }; then
    echo "SYNC_EXCLUDE_RE is not a valid extended regex: '$EXCLUDE_RE'" >&2; exit 1
  fi
fi

manifest=$(mktemp); envlist=$(mktemp)
trap 'rm -f "$manifest" "$envlist"' EXIT

echo "== discovering git repos under $CODE_ROOT =="
# `|| true`: find exits nonzero on any unreadable dir; that must not kill the run.
{ find "$CODE_ROOT" -maxdepth 7 \
    \( -name node_modules -o -name .venv -o -name venv -o -name target -o -name .next \) -prune \
    -o -name .git \( -type d -o -type f \) -print 2>/dev/null || true; } \
  | while read -r g; do
      d=$(dirname "$g"); rel=${d#"$CODE_ROOT/"}
      if [ -n "$EXCLUDE_RE" ] && echo "$rel" | grep -Eq "$EXCLUDE_RE"; then continue; fi
      url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
      # normalize both GitHub ssh forms to https (gh credential helper on the box)
      https=$(echo "$url" \
        | sed -e 's|^git@github.com:|https://github.com/|' \
              -e 's|^ssh://git@github.com/|https://github.com/|' \
              -e 's|\.git$||')
      case "$https" in
        https://github.com/*) echo "$rel|$https.git" ;;
        *) echo "SKIP non-github: $rel ($url)" >&2 ;;
      esac
    done | sort -t'|' -k1,1 -u \
  | awk -F'|' '{ for (k in kept) if (index($1, k "/") == 1) next; kept[$1]; print }' > "$manifest"
# ^ sorted on the PATH FIELD so a parent always precedes its children (prefix
#   sorts first); the awk drops any path nested under an already-kept repo.
#   Checking ALL kept roots matters: siblings like "parent-b" sort between
#   "parent" and "parent/sub", so last-seen tracking alone lets children through.
echo "  $(wc -l < "$manifest" | tr -d ' ') repos to mirror"

echo "== cloning on $DEVBOX_NAME (existing clones skipped) =="
# Remote script is the ssh argument; the manifest rides on stdin. git clone gets
# </dev/null so it can never eat the manifest lines.
ssh "$DEV_USER@$DEVBOX_NAME" 'bash -c '\''
  while IFS="|" read -r rel url; do
    [ -z "$rel" ] && continue
    if [ -d "$HOME/Code/$rel/.git" ]; then echo "SKIP $rel"; continue; fi
    mkdir -p "$HOME/Code/$(dirname "$rel")"
    if git clone -q "$url" "$HOME/Code/$rel" </dev/null 2>/dev/null; then echo "OK   $rel"
    else echo "FAIL $rel <- $url"; fi
  done
'\''' < "$manifest"

echo "== syncing .env files (never overwrites, skips untracked dirs) =="
{ find "$CODE_ROOT" -maxdepth 7 \
    \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name target -o -name .next \) -prune \
    -o \( -type f -o -type l \) -name ".env*" -print 2>/dev/null || true; } \
  | sed "s|^$CODE_ROOT/||" \
  | { if [ -n "$EXCLUDE_RE" ]; then grep -Ev "$EXCLUDE_RE" || true; else cat; fi; } > "$envlist"
echo "  $(wc -l < "$envlist" | tr -d ' ') env files found"

# Stage 1: ship the tarball (stdin = tar stream).
# COPYFILE_DISABLE stops macOS bsdtar from shipping AppleDouble (._*) junk.
COPYFILE_DISABLE=1 tar czf - -C "$CODE_ROOT" -T "$envlist" | ssh "$DEV_USER@$DEVBOX_NAME" \
  'bash -c "rm -rf ~/.env-staging && mkdir -p ~/.env-staging && tar xzf - -C ~/.env-staging"'

# Stage 2: place files (separate connection; no stdin contention).
ssh "$DEV_USER@$DEVBOX_NAME" 'bash -c '\''
  cd ~/.env-staging || exit 0
  find . -type f -name "._*" -delete
  find . \( -type f -o -type l \) | sed "s|^\./||" | sort | while read -r rel; do
    tgt="$HOME/Code/$rel"
    if [ ! -d "$(dirname "$tgt")" ]; then echo "SKIP no-dir  $rel"
    elif [ -e "$tgt" ]; then echo "SKIP exists  $rel"
    else cp "$rel" "$tgt" 2>/dev/null && chmod 600 "$tgt" && echo "COPIED       $rel" || echo "SKIP broken  $rel"; fi
  done
  cd / && rm -rf ~/.env-staging
'\'''
echo "done."
