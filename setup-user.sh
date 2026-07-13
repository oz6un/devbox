#!/usr/bin/env bash
# Apply the mert user environment to the devbox. Run from the Mac, idempotent —
# safe to re-run any time to converge drift. Requires the server to be on the
# tailnet already (./provision.sh).
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp files/config.fish files/tmux.conf files/vite-hosts.fish files/fnm.fish \
   files/claude-settings.json files/remote-setup.sh "$staging/"

# Render the notify hook from its template. Empty secrets are fine — the script
# skips channels whose placeholder was never filled.
sed -e "s|__PUSHOVER_TOKEN__|${PUSHOVER_TOKEN:-}|g" \
    -e "s|__PUSHOVER_USER__|${PUSHOVER_USER:-}|g" \
    -e "s|__NTFY_TOPIC__|${NTFY_TOPIC:-}|g" \
    files/claude-notify.tmpl > "$staging/claude-notify"

# COPYFILE_DISABLE stops macOS bsdtar from embedding AppleDouble (._*) junk.
COPYFILE_DISABLE=1 tar czf - -C "$staging" . | ssh "mert@$DEVBOX_NAME" \
  'rm -rf ~/.devbox-setup && mkdir -p ~/.devbox-setup && tar xzf - -C ~/.devbox-setup'

# shellcheck disable=SC2029  # client-side expansion of GIT_* is the point
ssh "mert@$DEVBOX_NAME" "GIT_NAME='$GIT_NAME' GIT_EMAIL='$GIT_EMAIL' bash ~/.devbox-setup/remote-setup.sh"

if ! grep -q "^Host $DEVBOX_NAME\$" ~/.ssh/config 2>/dev/null; then
  echo
  echo "Tip: add this to ~/.ssh/config on the Mac for 'ssh $DEVBOX_NAME' + fast reconnects:"
  sed "s/devbox/$DEVBOX_NAME/" files/mac-ssh-config.snippet
fi
