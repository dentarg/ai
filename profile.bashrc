export HOME=/workspace
export HISTFILE=/commandhistory/.bash_history
# append to history file after each command
export PROMPT_COMMAND="history -a"
# allows claude to start with --dangerously-skip-permissions as root
export IS_SANDBOX=1

cool_claude () {
  mkdir -p $HOME/.claude
  cp -f /settings/CLAUDE.md $HOME/.claude
  cp -f /settings/.claude.json $HOME/.claude.json
  claude \
    --dangerously-skip-permissions \
    --model opus
}
