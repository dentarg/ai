# due to https://github.com/ruby/rubygems/issues/9124
export BUNDLE_DEFAULT_CLI_COMMAND=install
export BUNDLE_IGNORE_FUNDING_REQUESTS=1 # no post install messages will be printed
export BUNDLE_IGNORE_MESSAGES=1 # no funding requests will be printed
export HOME=/workspace
export HISTFILE=/commandhistory/.bash_history
# append to history file after each command
export PROMPT_COMMAND="history -a"
# allows claude to start with --dangerously-skip-permissions as root
export IS_SANDBOX=1

alias b=bundle

link_dotfiles () {
  local dir=/settings/dotfiles

  for file in ${dir}/* ${dir}/.*; do
    [[ "$(basename $file)" == "*" ]] && continue
    ln -sf $file $HOME
  done
}

cool_claude () {
  local claude_home="/history/claude_$(date +%Y%m%d%H%M)"

  mkdir -p $claude_home
  ln -s $claude_home $HOME/.claude
  cp -f /settings/CLAUDE.md $HOME/.claude || true

  claude \
    --dangerously-skip-permissions \
    --model opus
}

link_dotfiles
