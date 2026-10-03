#!/bin/bash

# UserPromptSubmit hook dispatcher for Codex.
# Reads the prompt from stdin (JSON) and dispatches single-letter commands.
# Exit 2 = block prompt, exit 0 = pass through.

prompt=$(jq -r .prompt)

case "$prompt" in
  x)
    (sleep 0.1; pkill -INT -x codex 2>/dev/null) &
    echo "Exiting..." >&2
    exit 2
    ;;
esac
