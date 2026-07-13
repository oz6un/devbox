set -g fish_greeting ""
fish_add_path $HOME/.local/bin

if status is-interactive
    starship init fish | source
    zoxide init fish | source
    test -f /usr/share/doc/fzf/examples/key-bindings.fish; and source /usr/share/doc/fzf/examples/key-bindings.fish
    alias bat batcat
    alias fd fdfind
    command -sq eza; and alias ll "eza -la --git"; or alias ll "ls -la"
    set -gx EDITOR nvim
end

# Land in a persistent tmux session on interactive SSH logins
if status is-interactive; and set -q SSH_TTY; and not set -q TMUX; and command -sq tmux
    exec tmux new-session -A -s main
end
