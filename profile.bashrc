export HOME=/workspace
export HISTFILE=/commandhistory/.bash_history
# append to history file after each command
export PROMPT_COMMAND="history -a"
# allows claude to start with --dangerously-skip-permissions as root
export IS_SANDBOX=1

link_dotfiles () {
  local dir=/settings/dotfiles

  for file in ${dir}/* ${dir}/.*; do
    [[ "$file" == "." || "$file" == ".." ]] && continue
    ln -sf $(realpath $file) $HOME
  done
}

cool_claude () {
  local claude_home="/history/claude_$(date +%Y%m%d%H%M)"

  mkdir -p $claude_home
  ln -s $claude_home $HOME/.claude
  cp -f /settings/CLAUDE.md $HOME/.claude || true

  link_dotfiles

  claude \
    --dangerously-skip-permissions \
    --model opus
}
