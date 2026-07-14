#!/usr/bin/env bash
# Apply the dev-user environment to the devbox. Run from the Mac, idempotent —
# safe to re-run any time to converge drift. Requires the server to be on the
# tailnet already (./provision.sh).
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./secrets.env ] || { echo "secrets.env not found — cp secrets.env.example secrets.env and fill it in." >&2; exit 1; }
# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
DEV_USER="${DEV_USER:-dev}"

# Pushover keys render into a ROOT-executed script (devbox-health); real keys
# are alphanumeric, so enforce exactly that — kills the injection class.
for v in PUSHOVER_TOKEN PUSHOVER_USER; do
  val="${!v:-}"
  if [ -n "$val" ] && ! echo "$val" | grep -Eq '^[A-Za-z0-9]+$'; then
    echo "$v must be alphanumeric (Pushover keys always are): got something else." >&2; exit 1
  fi
done
# These land in sed replacements; refuse the metacharacters that would corrupt them.
for v in DEVBOX_NAME DEV_USER; do
  val="${!v:-}"
  # shellcheck disable=SC1003  # the quoted backslash is a literal glob char, not an escape
  case "$val" in
    *'|'*|*'&'*|*'\'*|*$'\n'*) echo "$v contains |, &, \\ or newline — not supported." >&2; exit 1 ;;
  esac
done

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp files/config.fish files/tmux.conf files/fnm.fish files/remote-setup.sh "$staging/"

# Render templates. Git identity and the skill list travel as plain files (not
# inline env) so their contents never meet the remote fish/bash quoting layers.
sed -e "s|__PUSHOVER_TOKEN__|${PUSHOVER_TOKEN:-}|g" \
    -e "s|__PUSHOVER_USER__|${PUSHOVER_USER:-}|g" \
    files/claude-notify.tmpl > "$staging/claude-notify"
sed -e "s|__PUSHOVER_TOKEN__|${PUSHOVER_TOKEN:-}|g" \
    -e "s|__PUSHOVER_USER__|${PUSHOVER_USER:-}|g" \
    files/devbox-health.tmpl > "$staging/devbox-health"
sed -e "s|__DEVBOX_NAME__|$DEVBOX_NAME|g" files/vite-hosts.fish > "$staging/vite-hosts.fish"
sed -e "s|__DEV_USER__|$DEV_USER|g" files/claude-settings.json > "$staging/claude-settings.json"
printf '%s' "${GIT_NAME:-}" > "$staging/git-name"
printf '%s' "${GIT_EMAIL:-}" > "$staging/git-email"
echo "${CLAUDE_SKILLS:-}" | tr ' \t' '\n' | grep -v '^$' > "$staging/claude-skills" || true
# Normalize the codex opt-in to 0/1 for the remote script.
case "${INSTALL_CODEX:-0}" in 1|true|yes|on) echo 1 ;; *) echo 0 ;; esac > "$staging/install-codex"

# COPYFILE_DISABLE stops macOS bsdtar from embedding AppleDouble (._*) junk.
COPYFILE_DISABLE=1 tar czf - -C "$staging" . | ssh "$DEV_USER@$DEVBOX_NAME" \
  'rm -rf ~/.devbox-setup && mkdir -p ~/.devbox-setup && tar xzf - -C ~/.devbox-setup'

ssh "$DEV_USER@$DEVBOX_NAME" 'bash ~/.devbox-setup/remote-setup.sh'

# Mac-side convenience: make `ssh <name>` work with connection reuse.
if ! grep -q "^Host $DEVBOX_NAME\$" ~/.ssh/config 2>/dev/null; then
  { echo ""; sed -e "s/devbox/$DEVBOX_NAME/" -e "s/__DEV_USER__/$DEV_USER/" files/mac-ssh-config.snippet; } >> ~/.ssh/config
  echo "Added 'Host $DEVBOX_NAME' block to ~/.ssh/config (user $DEV_USER + ControlMaster)."
fi
