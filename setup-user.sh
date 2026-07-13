#!/usr/bin/env bash
# Apply the mert user environment to the devbox. Run from the Mac, idempotent —
# safe to re-run any time to converge drift. Requires the server to be on the
# tailnet already (./provision.sh).
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./secrets.env ] || { echo "secrets.env not found — cp secrets.env.example secrets.env and fill it in." >&2; exit 1; }
# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"

# These land in sed replacements; refuse the metacharacters that would corrupt them.
for v in PUSHOVER_TOKEN PUSHOVER_USER NTFY_TOPIC DEVBOX_NAME; do
  val="${!v:-}"
  # shellcheck disable=SC1003  # the quoted backslash is a literal glob char, not an escape
  case "$val" in
    *'|'*|*'&'*|*'\'*|*$'\n'*) echo "$v contains |, &, \\ or newline — not supported." >&2; exit 1 ;;
  esac
done

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp files/config.fish files/tmux.conf files/fnm.fish \
   files/claude-settings.json files/remote-setup.sh "$staging/"

# Render templates. Git identity travels as plain files (not inline env) so
# apostrophes etc. never meet the remote fish/bash quoting layers.
sed -e "s|__PUSHOVER_TOKEN__|${PUSHOVER_TOKEN:-}|g" \
    -e "s|__PUSHOVER_USER__|${PUSHOVER_USER:-}|g" \
    -e "s|__NTFY_TOPIC__|${NTFY_TOPIC:-}|g" \
    files/claude-notify.tmpl > "$staging/claude-notify"
sed -e "s|__DEVBOX_NAME__|$DEVBOX_NAME|g" files/vite-hosts.fish > "$staging/vite-hosts.fish"
printf '%s' "${GIT_NAME:-}" > "$staging/git-name"
printf '%s' "${GIT_EMAIL:-}" > "$staging/git-email"

# COPYFILE_DISABLE stops macOS bsdtar from embedding AppleDouble (._*) junk.
COPYFILE_DISABLE=1 tar czf - -C "$staging" . | ssh "mert@$DEVBOX_NAME" \
  'rm -rf ~/.devbox-setup && mkdir -p ~/.devbox-setup && tar xzf - -C ~/.devbox-setup'

ssh "mert@$DEVBOX_NAME" 'bash ~/.devbox-setup/remote-setup.sh'

# Mac-side convenience: make `ssh <name>` work with connection reuse.
if ! grep -q "^Host $DEVBOX_NAME\$" ~/.ssh/config 2>/dev/null; then
  { echo ""; sed "s/devbox/$DEVBOX_NAME/" files/mac-ssh-config.snippet; } >> ~/.ssh/config
  echo "Added 'Host $DEVBOX_NAME' block to ~/.ssh/config (user mert + ControlMaster)."
fi
