#!/usr/bin/env bash
# Runs ON the devbox as mert (piped by setup-user.sh). Idempotent.
set -euo pipefail
S="$HOME/.devbox-setup"

echo "== shell + terminal config =="
mkdir -p ~/.config/fish/conf.d ~/.local/bin
cp "$S/config.fish" ~/.config/fish/config.fish
cp "$S/vite-hosts.fish" ~/.config/fish/conf.d/vite-hosts.fish
cp "$S/fnm.fish" ~/.config/fish/conf.d/fnm.fish
cp "$S/tmux.conf" ~/.tmux.conf

echo "== starship prompt =="
command -v starship >/dev/null || curl -sS https://starship.rs/install.sh | sh -s -- -y >/dev/null

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
[ -d ~/.claude/skills/ship-loop ] || git clone -q https://github.com/oz6un/ship-loop.git ~/.claude/skills/ship-loop

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
