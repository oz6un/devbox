# devbox

Reproduces a personal Hetzner development server from zero: a €5.49/mo CX23 in Falkenstein
that is **tailnet-only** (zero public TCP ports), hardened, and fully kitted for
development — fish + starship, persistent tmux, Node/pnpm, Claude Code with phone
notifications, and a transparent proxy that makes `http://devbox:<port>` reach any
dev server on the box (unprivileged ports, ≥1024). Tools install at their
latest versions on rebuild day — configs are pinned, versions are not.

## Architecture (what you get)

| Layer | Choice | Why |
|---|---|---|
| Access | **Tailscale SSH only** (`ssh devbox`, as `$DEV_USER`) | No SSH keys to manage; auth = tailnet identity; public 22 never opens |
| Firewall | UFW default-deny; only 41641/udp public | Everything else rides the tailnet interface |
| Hardening | key-only sshd (defense in depth), unattended-upgrades + 04:00 auto-reboot | Self-patching; nothing listens publicly, so no ban-daemon needed |
| Sessions | tmux auto-attach on SSH + resurrect/continuum | Survives disconnects *and* the 04:00 patch reboots |
| Localhost preview | iptables(-nft) REDIRECT → `tailnet-devproxy.py` (SO_ORIGINAL_DST) | `http://devbox:<port>` works even for servers bound to `127.0.0.1`/`::1` |
| Notifications | Claude Code hooks → Pushover | Presence-aware; includes StopFailure (API-error) alerts |
| Recovery | Hetzner rescue mode / console after a root-password reset | No credentials exist on the box — reset via Hetzner first |

## Prerequisites

On the Mac: `curl`, `jq`, `git`, `ssh` (all stock), Tailscale running and logged in,
and — for the code sync — your `~/Code` tree. All knobs (server name, dev user,
location, skills to install) live in `secrets.env`.

On the tailnet (hard requirements — provision's wait loop depends on them):
**MagicDNS on** (`$DEV_USER@devbox` must resolve) and **Tailscale SSH permitted by the
ACLs** (the default policy allows it). Verify both for your tailnet (new tailnets have them by default).

## Provision

```sh
cp secrets.env.example secrets.env   # fill in HCLOUD_TOKEN + TS_AUTHKEY
make provision                       # create server; cloud-init hardens + joins tailnet (~5-10 min)
make setup                           # user env: fish/tmux/node/claude/hooks (idempotent, re-runnable)
# one-time interactive auth on the box (see below), then:
make sync                            # mirror ~/Code repos + .env files
```

## Manual steps (unavoidable — interactive auth)

| Step | Where | Why it can't be automated |
|---|---|---|
| `gh auth login` | on devbox | GitHub device-code flow (gives the box its own revocable token) |
| `claude` → login | on devbox | Claude subscription OAuth in your browser |
| Disable key expiry | [Tailscale admin](https://login.tailscale.com/admin/machines) → devbox → ⋯ | Node key otherwise expires in ~180 days, killing the only SSH path |
| Notification devices | Pushover app + account (keys in secrets.env) | Phone-side app state can't be provisioned from here |
| Revoke `HCLOUD_TOKEN` | Hetzner console | Nothing needs it after provisioning |

Optional tailnet extra (already enabled here): **Tailscale Serve** for HTTPS
preview URLs — nothing in this repo depends on it.

## Rebuilding

`provision.sh` refuses to run if a server named `$DEVBOX_NAME` exists. To rebuild:
delete the server in Hetzner, **delete the old node in the Tailscale admin console**
(otherwise the new node becomes `devbox-1` and every `devbox` reference breaks),
generate a fresh `TS_AUTHKEY`, then run the three steps above.

`setup-user.sh` is safe to re-run any time to converge config drift on a live box.

## What is deliberately NOT here

- **Hetzner backups** — decide per-rebuild (+20% ≈ €1.10/mo, one API call or console toggle).
- **Project data** (databases, `./data` dirs) — repos and `.env` files are mirrored; runtime state is not.
- **Claude/gh credentials** — each box gets fresh, independently-revocable logins.

See [docs/FOOTGUNS.md](docs/FOOTGUNS.md) before changing anything — every entry
in that file cost real debugging time.
