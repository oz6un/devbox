#!/usr/bin/env bash
# Runs ON the devbox as the dev user, executed as a staged FILE by
# setup-user.sh (never via stdin — the sudo/heredoc blocks below depend on
# stdin staying free). Idempotent.
set -euo pipefail
S="$HOME/.devbox-setup"

echo "== shell + terminal config =="
mkdir -p ~/.config/fish/conf.d ~/.local/bin
cp "$S/config.fish" ~/.config/fish/config.fish
cp "$S/vite-hosts.fish" ~/.config/fish/conf.d/vite-hosts.fish
cp "$S/fnm.fish" ~/.config/fish/conf.d/fnm.fish
cp "$S/tmux.conf" ~/.tmux.conf

echo "== starship prompt =="
# Install to ~/.local/bin (already on PATH via config.fish) — a per-user tool,
# no sudo. The default /usr/local/bin target makes the installer call sudo,
# which has no tty over scripted ssh.
[ -x ~/.local/bin/starship ] || curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" >/dev/null

echo "== tmux plugins (resurrect/continuum) =="
[ -d ~/.tmux/plugins/tpm ] || git clone -q https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
tmux start-server 2>/dev/null || true
~/.tmux/plugins/tpm/bin/install_plugins >/dev/null || true

echo "== node toolchain (fnm + node 24 + pnpm via corepack) =="
if [ ! -d ~/.local/share/fnm ]; then
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell >/dev/null
fi
export PATH="$HOME/.local/share/fnm:$PATH"
# Explicit shell: fnm autodetection under SHELL=fish could emit fish syntax.
eval "$(fnm env --shell bash)"
fnm install 24 >/dev/null   # stderr stays visible — it's the diagnostic on failure
fnm default 24
corepack enable 2>/dev/null || true

echo "== claude code =="
[ -x ~/.local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash >/dev/null
mkdir -p ~/.claude/skills
if [ -f ~/.claude/settings.json ]; then
  jq -s '.[0] * .[1]' ~/.claude/settings.json "$S/claude-settings.json" > ~/.claude/settings.json.tmp \
    && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
else
  cp "$S/claude-settings.json" ~/.claude/settings.json
fi
install -m 700 "$S/claude-notify" ~/.local/bin/claude-notify
# Skills: one git URL per line in $S/claude-skills (from CLAUDE_SKILLS in
# secrets.env). A bad URL warns and continues — it must not abort the setup.
while IFS= read -r skill_url; do
  [ -z "$skill_url" ] && continue
  name=$(basename "$skill_url" .git)
  if [ ! -d ~/.claude/skills/"$name" ]; then
    git clone -q "$skill_url" ~/.claude/skills/"$name" </dev/null 2>/dev/null \
      || echo "WARN: skill clone failed: $skill_url"
  fi
done < "$S/claude-skills"

# Optional: OpenAI Codex CLI (npm) + bubblewrap (its Linux sandbox). npm is on
# PATH from the node section above. Auth is a separate one-time `codex login`.
if [ "$(cat "$S/install-codex" 2>/dev/null)" = 1 ]; then
  echo "== codex cli (optional) =="
  command -v codex >/dev/null || npm install -g @openai/codex >/dev/null 2>&1 \
    || echo "WARN: codex install failed"
  command -v bwrap >/dev/null \
    || sudo DEBIAN_FRONTEND=noninteractive apt-get -yq install bubblewrap >/dev/null 2>&1 \
    || echo "WARN: bubblewrap install failed (codex falls back to a bundled copy)"
  # Phone notifications (same Pushover pipe as Claude): Codex calls a `notify`
  # program on agent-turn-complete. Wire it via config.toml's root `notify` key,
  # which per TOML must precede any [tables] — so prepend it; idempotent.
  install -m 700 "$S/codex-notify" ~/.local/bin/codex-notify
  mkdir -p ~/.codex
  if ! grep -q '^notify' ~/.codex/config.toml 2>/dev/null; then
    if [ -f ~/.codex/config.toml ]; then
      sed -i "1i notify = [\"$HOME/.local/bin/codex-notify\"]" ~/.codex/config.toml
    else
      echo "notify = [\"$HOME/.local/bin/codex-notify\"]" > ~/.codex/config.toml
    fi
  fi
fi

# Optional: Moonshot Kimi Code CLI (K3). Node-independent installer from the
# GLOBAL mirror (code.kimi.ai => region "global"; code.kimi.com is mainland-CN
# and would point login at the wrong OAuth host). Auth is a one-time `kimi login`
# (RFC 8628 device-code flow — headless-friendly, no localhost callback port).
if [ "$(cat "$S/install-kimi" 2>/dev/null)" = 1 ]; then
  echo "== kimi code cli (optional) =="
  # KIMI_NO_MODIFY_PATH: config.fish owns PATH (it adds ~/.kimi-code/bin when
  # present), so the installer must not append its own line — a config.fish
  # re-copy on the next setup would drop it while the install guard skips a
  # reinstall, silently losing `kimi` from PATH.
  [ -x ~/.kimi-code/bin/kimi ] \
    || curl -fsSL https://code.kimi.ai/kimi-code/install.sh | KIMI_NO_MODIFY_PATH=1 bash >/dev/null 2>&1 \
    || echo "WARN: kimi install failed"
  install -m 700 "$S/kimi-notify" ~/.local/bin/kimi-notify
  # Phone notifications: Stop (turn hand-back) + StopFailure -> Pushover, the same
  # pipe as Claude/Codex. ~/.kimi-code/config.toml is written by `kimi login`, so
  # it may not exist until that one-time auth — inject only when it's present and
  # not already wired (idempotent; overwriting it would drop default_model +
  # providers => "No model configured"). Re-run `make setup` after `kimi login`.
  if [ -f ~/.kimi-code/config.toml ] && ! grep -q 'kimi-notify' ~/.kimi-code/config.toml; then
    cat >> ~/.kimi-code/config.toml <<EOF

# Phone notifications (managed by devbox setup; do not duplicate).
[[hooks]]
event = "Stop"
command = "$HOME/.local/bin/kimi-notify"

[[hooks]]
event = "StopFailure"
command = "$HOME/.local/bin/kimi-notify"
EOF
  elif [ ! -f ~/.kimi-code/config.toml ]; then
    echo "   note: run \`kimi login\`, then re-run make setup to wire notifications"
  fi
fi

echo "== git identity =="
# Identity arrives as files (see setup-user.sh) so no quoting layer ever parses it.
GIT_NAME=$(cat "$S/git-name" 2>/dev/null || true)
GIT_EMAIL=$(cat "$S/git-email" 2>/dev/null || true)
if [ -n "$GIT_NAME" ]; then git config --global user.name "$GIT_NAME"; fi
if [ -n "$GIT_EMAIL" ]; then git config --global user.email "$GIT_EMAIL"; fi
git config --global init.defaultBranch main

rm -rf "$S"
echo
echo "✅ user environment applied. Manual steps that need YOUR auth (one-time):"
echo "   gh auth login          # GitHub device flow (HTTPS + credential helper)"
echo "   claude                 # Claude Code login (subscription OAuth)"
echo "   Then: ./sync-code.sh from the Mac to mirror repos + .env files."
