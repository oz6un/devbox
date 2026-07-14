#!/usr/bin/env bash
# Tear the devbox down: delete the Hetzner server and clean local state. The
# inverse of provision.sh, using the same secrets.env. Removing the Tailscale
# node is manual (no Tailscale API key is in scope) — the exact step is printed.
#
#   make destroy              # confirm by typing the name
#   FORCE=1 make destroy      # skip the prompt (CI / scripted)
#   DRY_RUN=1 make destroy     # show what would happen, delete nothing
set -euo pipefail
cd "$(dirname "$0")"

[ -f ./secrets.env ] || { echo "secrets.env not found." >&2; exit 1; }
# shellcheck disable=SC1091
source ./secrets.env
: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN in secrets.env}"
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
DEV_USER="${DEV_USER:-dev}"
# Normalize the flags: only explicit truthy values enable FORCE (default = ask),
# and ANY non-false value keeps DRY_RUN on — a "preview" flag must never delete
# by accident (DRY_RUN=true/yes previously slipped through as "not dry").
case "${FORCE:-0}"   in 1|true|yes|on) FORCE=1 ;; *) FORCE=0 ;; esac
case "${DRY_RUN:-0}" in 0|false|no|"") DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac

# Look up the server, distinguishing "0 servers" from an API/auth error. A
# revoked token (secrets.env.example tells you to revoke it!) returns 401 with
# an empty .servers parse — which must NOT read as "nothing to delete" while a
# server keeps billing.
resp=$(curl -s -w $'\n%{http_code}' --max-time 10 \
  -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/servers?name=$DEVBOX_NAME") \
  || { echo "Hetzner API unreachable." >&2; exit 1; }
code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" != 200 ]; then
  echo "Hetzner API returned HTTP $code (token revoked, or wrong project?)." >&2
  echo "Cannot verify server state — aborting rather than assume it's gone." >&2
  exit 1
fi
count=$(printf '%s' "$body" | jq '.servers | length')
if [ "$count" -gt 1 ]; then
  echo "Multiple servers named '$DEVBOX_NAME' exist — refusing to guess which." >&2
  echo "Delete the intended one via the Hetzner console." >&2
  exit 1
fi
id=$(printf '%s' "$body" | jq -r '.servers[0].id // empty')

if [ -z "$id" ]; then
  echo "No Hetzner server named '$DEVBOX_NAME' — nothing to delete."
else
  echo "Found server '$DEVBOX_NAME' (id $id)."
  if [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf "Type the server name to confirm PERMANENT deletion: "
    read -r ans
    [ "$ans" = "$DEVBOX_NAME" ] || { echo "Aborted."; exit 1; }
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would log out the tailnet node, then DELETE /v1/servers/$id"
  else
    # Best-effort: drop the node from the tailnet before the box vanishes (the
    # operator user can run this without sudo). Never blocks the delete.
    ssh -o ConnectTimeout=6 "$DEV_USER@$DEVBOX_NAME" 'tailscale logout' 2>/dev/null \
      || ssh -o ConnectTimeout=6 "$DEV_USER@$DEVBOX_NAME" 'sudo tailscale logout' 2>/dev/null \
      || true
    del=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X DELETE \
      -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/servers/$id") \
      || { echo "DELETE request failed to reach the API." >&2; exit 1; }
    if [ "$del" = 200 ] || [ "$del" = 204 ]; then
      echo "Server deleted (HTTP $del). Billing stopped."
    else
      echo "Delete failed (HTTP $del)." >&2
      exit 1
    fi
  fi
fi

# Local cleanup: a rebuilt node presents a new SSH host key under the same name.
if [ "$DRY_RUN" != 1 ]; then
  ssh-keygen -R "$DEVBOX_NAME" >/dev/null 2>&1 || true
fi

echo
echo "Manual step (no Tailscale API key in scope):"
echo "  Remove the '$DEVBOX_NAME' node → https://login.tailscale.com/admin/machines"
echo "  Skip this and a rebuild registers as '$DEVBOX_NAME-1', breaking MagicDNS."
