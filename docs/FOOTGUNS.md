# Footguns

Non-obvious lessons from building the original box (2026-07-13). Each of these
broke something in practice; don't re-learn them.

## Networking / preview proxy

- **Kernel REDIRECT alone can't reach loopback-only servers.** iptables `REDIRECT`
  rewrites the destination to the *interface* address, so a Vite bound to `::1`
  never sees the packet — and IPv6 can't NAT to loopback at all. That's why
  `tailnet-devproxy.py` exists: single-port REDIRECT + `SO_ORIGINAL_DST` recovery,
  then a userspace dial to `::1`/`127.0.0.1`. Don't "simplify" it back to plain NAT.
- **The devproxy exposes every localhost TCP service (ports ≥1024) to the tailnet.**
  Fine for a single-person tailnet; revisit if you ever share the tailnet.
- **Vite's `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` takes exactly ONE host.**
  A comma list is treated as a single literal hostname and silently matches nothing
  (see the singular `additionalHost` in Vite's source).
- **Per-app origin checks are a separate layer.** Example: derive's Better Auth
  needs `DERIVE_WEB_ORIGIN=http://devbox:3090` in the repo's `.env` — the Vite proxy
  rewrites `Host`, defeating the API's same-origin rescue.

## Tailscale

- **`tailscale serve` needs a one-time tailnet enable** (a `login.tailscale.com/f/serve`
  approval link) — the CLI silently blocks until it's clicked.
- **Node key expiry must be disabled per node.** Tailscale SSH is the ONLY access
  path; an expired node key = locked out until re-auth (break-glass: Hetzner rescue).
- **Rebuilds: delete the old tailnet node first**, or the new machine registers as
  `devbox-1` and MagicDNS references break.
- **Tailscale SSH sessions don't read `/etc/environment`** (no PAM) — machine-wide
  env vars must go in shell config (`/etc/profile.d` + fish `conf.d`).

## Shell / tmux

- **Root's login shell being fish breaks naive automation:** `ssh devbox '...'`
  runs fish, where `$?`, heredocs-with-bashisms etc. differ. Always `bash -s` /
  `bash -c` for scripted SSH.
- **tmux `run "<tpm path>"` must be per-user.** A config copied from another user
  with an absolute `/root/.tmux/...` path silently loads zero plugins — resurrect
  "works" until the first reboot eats every session. Use `~/.tmux/plugins/tpm/tpm`.
- **`tmux kill-server` immediately followed by `new-session` races** ("server exited
  unexpectedly"). Sleep ~2s between.

## macOS quirks

- **bsdtar ships AppleDouble (`._*`) files** into Linux hosts — set
  `COPYFILE_DISABLE=1` when tar-ing from the Mac.
- **Stock macOS has no `timeout` or `envsubst`** — scripts here use `sed` and
  polling loops instead.

## Claude Code

- **`--dangerously-skip-permissions` refuses to run as root** — that's the whole
  reason the `mert` user exists. Keep dev work off root.
- **Hooks:** `async: true` keeps notifications from delaying turns; `StopFailure`
  is the only signal when a long run dies on a rate limit/API error; the presence
  check (tmux `client_activity`) prevents push spam while you're at the keyboard.
- **pnpm 10 blocks dependency build scripts by default** (`pnpm approve-builds`) —
  a repo may need approval before native modules work.

## Hetzner

- **Servers bill while powered off** — delete (after snapshot) to stop paying.
- **Rescue mode is the break-glass** for a box with no root password and no SSH
  keys; it works regardless of what's on the disk.
