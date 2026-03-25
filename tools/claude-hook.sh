#!/bin/bash

# UserPromptSubmit hook dispatcher for Claude Code.
# Reads the prompt from stdin (JSON) and dispatches single-letter commands.
# Exit 2 = block prompt, exit 0 = pass through.

prompt=$(jq -r .prompt)

case "$prompt" in
  x)
    (sleep 0.1; pkill -INT claude 2>/dev/null) &
    echo "Exiting..." >&2
    exit 2
    ;;
  l)
    profile=$(cat "$HOME/.claude/.profile" 2>/dev/null)
    /app/tools/claude-login.sh "$profile" >&2
    exit 2
    ;;
esac
