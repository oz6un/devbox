#!/usr/bin/env bash
# Provision the devbox on Hetzner Cloud from scratch. Run from the Mac.
# Requires: curl, jq, ssh. Reads secrets.env (see secrets.env.example).
# After this script finishes you have a hardened, tailnet-joined server;
# run ./setup-user.sh next for the user environment.
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./secrets.env ] || { echo "secrets.env not found — cp secrets.env.example secrets.env and fill it in." >&2; exit 1; }
# shellcheck disable=SC1091
source ./secrets.env
: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN in secrets.env (Hetzner Cloud API token, read+write)}"
: "${TS_AUTHKEY:?set TS_AUTHKEY in secrets.env (tailscale pre-auth key, pre-approved, non-reusable)}"
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
# The name lands in sed replacements, YAML, a shell command, and a URL — keep it boring.
if ! echo "$DEVBOX_NAME" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
  echo "DEVBOX_NAME must be lowercase RFC1123 (letters/digits/hyphens): got '$DEVBOX_NAME'" >&2
  exit 1
fi
SERVER_TYPE="${SERVER_TYPE:-cx23}"
LOCATION="${LOCATION:-fsn1}"
IMAGE="${IMAGE:-ubuntu-24.04}"

api() {
  local method=$1 path=$2 body=${3:-}
  curl -fsS -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" \
    -H "Content-Type: application/json" ${body:+-d "$body"} \
    "https://api.hetzner.cloud/v1$path"
}

# Guard: no declarative state here — a second run must not create a twin.
existing=$(api GET "/servers?name=$DEVBOX_NAME" | jq '.servers | length')
if [ "$existing" != "0" ]; then
  echo "ERROR: a server named '$DEVBOX_NAME' already exists in this Hetzner project." >&2
  echo "This script provisions from scratch; to rebuild, delete the old server (and its" >&2
  echo "tailnet node in the Tailscale admin console) first." >&2
  exit 1
fi

# Render cloud-init. sed, not envsubst (not on stock macOS). Tailscale auth keys
# are [A-Za-z0-9-] so they are safe inside a sed replacement.
user_data=$(sed -e "s|\${TS_AUTHKEY}|$TS_AUTHKEY|g" \
                -e "s|\${DEVBOX_NAME}|$DEVBOX_NAME|g" cloud-init.yaml)

echo "Creating $SERVER_TYPE '$DEVBOX_NAME' in $LOCATION..."
payload=$(jq -n --arg name "$DEVBOX_NAME" --arg type "$SERVER_TYPE" \
                --arg image "$IMAGE" --arg loc "$LOCATION" --arg ud "$user_data" \
  '{name:$name, server_type:$type, image:$image, location:$loc, user_data:$ud,
    public_net:{enable_ipv4:true, enable_ipv6:true}, start_after_create:true}')
server_id=$(api POST "/servers" "$payload" | jq -r '.server.id')
echo "Server created (id $server_id). Waiting for it to boot..."

for _ in $(seq 1 40); do
  sleep 5
  status=$(api GET "/servers/$server_id" | jq -r '.server.status')
  [ "$status" = "running" ] && break
done
echo "Server is $status. Cloud-init is now installing packages and joining the"
echo "tailnet — this takes several minutes (full apt upgrade + possible reboot)."

# A rebuilt node generates a fresh SSH host key under the same MagicDNS name;
# a stale known_hosts entry would make every probe below hard-fail silently.
ssh-keygen -R "$DEVBOX_NAME" >/dev/null 2>&1 || true

echo "Waiting for Tailscale SSH as mert@$DEVBOX_NAME (up to 15 min)..."
for i in $(seq 1 60); do
  sleep 15
  if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
       "mert@$DEVBOX_NAME" true 2>/dev/null; then
    echo
    echo "✅ $DEVBOX_NAME is up, hardened, and on your tailnet."
    echo "Next steps:"
    echo "  1. ./setup-user.sh          # user environment (fish, tmux, node, claude, hooks)"
    echo "  2. ./sync-code.sh           # mirror ~/Code repos + .env files"
    echo "  3. Disable key expiry for '$DEVBOX_NAME' in the Tailscale admin console"
    echo "     (Machines -> $DEVBOX_NAME -> ... -> Disable key expiry) — it is the only SSH path."
    exit 0
  fi
  [ $((i % 8)) = 0 ] && echo "  ...still waiting (${i}x15s)" || true
done

echo "ERROR: server never became reachable over Tailscale SSH." >&2
echo "Check: https://login.tailscale.com/admin/machines (did the node join?)," >&2
echo "and the Hetzner console for cloud-init output (server $server_id)." >&2
exit 1
