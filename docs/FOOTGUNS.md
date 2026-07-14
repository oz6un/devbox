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

## Docker

- **Docker bypasses UFW completely.** Published ports ride Docker's own NAT +
  FORWARD chains and never hit the INPUT chain where UFW lives — `-p 8080:80`
  is internet-reachable on a default-deny box. Our fix: `/etc/docker/daemon.json`
  sets `"ip": "127.0.0.1"` so publishes default to loopback (tailnet still
  reaches them through the devproxy). An explicit `-p 0.0.0.0:8080:80` STILL
  bypasses everything — never do that here.
- **The inverse footgun: `ufw enable`/`ufw reload` flushes Docker's FORWARD
  chains** (filter-table restore without --noflush) — loopback publishes keep
  working but container egress dies until `systemctl restart docker`. cloud-init
  orders a docker restart after ufw enable for this; remember it after any
  manual `ufw reload`.

## Tailscale

- **A stopped Tailscale client (not the server) shows up as `Could not resolve
  hostname <name>`.** The Mac dropping off the tailnet — common after sleep —
  looks identical to a server problem. Check `tailscale status`; `tailscale up`
  fixes it. `make preflight` now catches this before provisioning.

- **`tailscale serve` needs a one-time tailnet enable** (a `login.tailscale.com/f/serve`
  approval link) — the CLI silently blocks until it's clicked.
- **Node key expiry must be disabled per node.** Tailscale SSH is the ONLY access
  path; an expired node key = locked out until re-auth (break-glass: Hetzner rescue).
- **Rebuilds: delete the old tailnet node first**, or the new machine registers as
  `devbox-1` and MagicDNS references break.
- **Tailscale SSH sessions don't read `/etc/environment`** (no PAM) — machine-wide
  env vars must go in shell config (`/etc/profile.d` + fish `conf.d`).

## Shell / tmux

- **The login shell being fish breaks naive automation:** `ssh devbox '...'`
  runs fish (the dev user's shell — and root's too on the original box, though
  rebuilds deliberately keep root on bash), where `$?`, heredocs-with-bashisms
  etc. differ. Always `bash -s` / `bash -c` for scripted SSH.
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
  reason the non-root dev user exists. Keep dev work off root.
- **Hooks:** `async: true` keeps notifications from delaying turns; `StopFailure`
  is the only signal when a long run dies on a rate limit/API error; the presence
  check (tmux `client_activity`) prevents push spam while you're at the keyboard.
- **pnpm 10 blocks dependency build scripts by default** (`pnpm approve-builds`) —
  a repo may need approval before native modules work.

## cloud-init (learned auditing this repo)

- **`chsh` in runcmd fails for a `lock_passwd: true` user** — PAM rejects a
  shell change on an account with no password ("authentication token is no
  longer valid"). Set the shell in the `users:` block instead (`shell:
  /usr/bin/fish`); useradd records the path even though fish isn't installed
  until the final stage — it exists before anyone logs in. (Found by rebuild.)
- **A per-user tool that installs to `/usr/local/bin` calls `sudo`, which has
  no tty over scripted ssh** — starship's installer did this and aborted
  ("a terminal is required"). Install such tools to `~/.local/bin` (already on
  PATH) with the installer's bin-dir flag; no sudo, matches claude/fnm. NOTE:
  `sudo -n` (used by the health-timer setup) works fine non-tty — the problem
  is installers that shell out to bare `sudo`. (Found by rebuild.)
- **`gh auth login --web` on a box with ANY text browser blocks forever** —
  its "open browser" step launches the browser (w3m/links pulled in by some
  package) which then sits on a cookie prompt instead of failing cleanly like
  a browserless box. Run it as `BROWSER=/usr/bin/true gh auth login …` so the
  open-step is a no-op and gh proceeds to device-flow polling. (Found by rebuild.)

- **Never put `reboot` in runcmd.** runcmd is NOT the last module; a bare reboot
  interrupts cloud-init mid-final-stage, marks the boot failed, and can re-run
  the whole runcmd on second boot. Use the `power_state` module — it runs dead
  last with clean teardown.
- **Hetzner + no ssh_keys ⇒ cloud-init writes `50-cloud-init.conf` with
  `PasswordAuthentication yes`, and 50- lexically beats a 99- drop-in** (sshd is
  first-match-wins). Set top-level `ssh_pwauth: false` in user-data; a hardening
  drop-in alone is silently defeated.
- **The `packages:` list is one apt transaction** — a single bad package name
  skips ALL of them (no ufw, no fish) while runcmd still runs.
  Verify names against noble before adding anything.

## Reproduction / sync

- **Box-local `.env` files are invisible to the mirror.** sync-code.sh copies
  Mac→box only. If a project needs a devbox-specific value (derive's
  `DERIVE_WEB_ORIGIN=http://devbox:3090`), the file must live on the Mac —
  that's why `~/Code/derive-to/derive/.env` exists there. Never create config
  only on the box.
- **Changing `DEV_USER` on an existing setup leaves a stale `Host` block** in
  the Mac's ~/.ssh/config (setup-user.sh only appends when absent) — update or
  remove it by hand, or `ssh` silently targets the old user.
- **Rebuilds change the Tailscale SSH host key** under the same MagicDNS name;
  stale `known_hosts` entries make every connection hard-fail. provision.sh
  runs `ssh-keygen -R` for this; do the same on other machines that connected.

## Deliberately removed (don't re-add reflexively)

- **fail2ban**: with public 22 never open and Tailscale SSH bypassing sshd, it
  logged 0 failed attempts ever — a permanently idle daemon. Re-add only if you
  deliberately expose sshd to the internet.
- **ntfy mirror in claude-notify**: nothing subscribed to the topic after
  Pushover won; it was a second HTTP call per event to nobody. Single-channel
  now; ntfy is ~15 lines to re-add if a free/desktop channel is ever wanted.
- **mosh**: can't bootstrap through **Tailscale SSH** — `tailscaled` swallows all
  TCP :22 packets after WireGuard decryption and never hands them to the kernel's
  sshd, and mosh needs a *real* OpenSSH server to launch `mosh-server`. Verified
  end-to-end (SSH auth + `mosh-server` + bidirectional UDP all work, yet the mosh
  handshake fails on both a Mac and a phone) — see Tailscale issue #4919. Not a
  firewall or locale problem; the design is fundamentally incompatible. tmux
  already covers session survival (and survives reboots, which mosh can't). To
  actually get mosh, run classic OpenSSH on a non-22 port (tailscaled owns 22) +
  a device key, and point the client's mosh at that port — an opt-in worth adding
  only if someone genuinely wants the instant-echo feel.

## Hetzner

- **Servers bill while powered off** — delete (after snapshot) to stop paying.
- **Rescue mode is the break-glass**, but note: provisioned this way the box has
  no usable root password (Hetzner returns one in the create response; the
  script discards it and it's born expired). Console access requires a Hetzner
  password reset first; rescue mode works regardless.
