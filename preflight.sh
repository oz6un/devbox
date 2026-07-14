#!/usr/bin/env bash
# Fail fast BEFORE provision creates any billable resource. Run standalone with
# `make preflight`, and automatically as the first step of provision.sh. Every
# check is read-only; a ✗ tells you exactly what to fix.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

fail=0
ok()  { echo "  ✓ $1"; }
err() { echo "  ✗ $1" >&2; fail=1; }

echo "Preflight:"

if [ ! -f ./secrets.env ]; then
  err "secrets.env missing — cp secrets.env.example secrets.env and fill it in."
  exit 1
fi
# shellcheck disable=SC1091
source ./secrets.env
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"

# Local CLIs the scripts call.
for c in curl jq ssh tailscale git; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c on PATH"; else err "$c not found on PATH"; fi
done

# Hetzner token — distinguish "wrong token" from "network down".
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  err "HCLOUD_TOKEN empty in secrets.env"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers || echo 000)
  case "$code" in
    200) ok "Hetzner token valid" ;;
    401) err "Hetzner token rejected (401) — check HCLOUD_TOKEN" ;;
    *)   err "Hetzner API unreachable (HTTP $code)" ;;
  esac
fi

# Tailscale pre-auth key format.
case "${TS_AUTHKEY:-}" in
  tskey-*) ok "TS_AUTHKEY format looks right" ;;
  "")      err "TS_AUTHKEY empty — generate one (reusable off, ephemeral off, pre-approved)" ;;
  *)       err "TS_AUTHKEY doesn't look like a tskey-… key" ;;
esac

# Tailscale up + MagicDNS: provision's wait loop resolves \$DEV_USER@\$DEVBOX_NAME
# by name, so a stopped client or MagicDNS-off tailnet makes it time out blind.
# (This is exactly the "Could not resolve hostname" class of failure.)
if tailscale status >/dev/null 2>&1; then
  ok "Tailscale is up"
  if tailscale status --json 2>/dev/null | jq -e '.CurrentTailnet.MagicDNSEnabled == true' >/dev/null 2>&1; then
    ok "MagicDNS enabled"
  else
    err "MagicDNS is off — enable it (Tailscale admin → DNS); provision resolves the box by name"
  fi
else
  err "Tailscale is not running — run 'tailscale up' on this machine first"
fi

# Name must be free — otherwise provision would refuse anyway, but say so now.
# Validate the HTTP status: an error body must not parse to a false "0 / free".
if [ -n "${HCLOUD_TOKEN:-}" ]; then
  resp=$(curl -s -w $'\n%{http_code}' --max-time 10 -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/servers?name=$DEVBOX_NAME" || true)
  code=${resp##*$'\n'}
  if [ "$code" = 200 ]; then
    n=$(printf '%s' "${resp%$'\n'*}" | jq '.servers | length' 2>/dev/null || echo "?")
    case "$n" in
      0)   ok "server name '$DEVBOX_NAME' is free" ;;
      "?") err "couldn't parse the Hetzner server list" ;;
      *)   err "a server named '$DEVBOX_NAME' already exists — pick another DEVBOX_NAME or destroy it" ;;
    esac
  else
    err "couldn't check name '$DEVBOX_NAME' (Hetzner HTTP ${code:-unreachable})"
  fi
fi

if [ "$fail" = 0 ]; then
  echo "Preflight OK."
else
  echo "Preflight FAILED — fix the ✗ items above before provisioning." >&2
  exit 1
fi
