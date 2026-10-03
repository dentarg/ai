#!/bin/bash

# UserPromptSubmit hook dispatcher for Codex.
# Reads the prompt from stdin (JSON) and dispatches single-letter commands.
# Exit 2 = block prompt, exit 0 = pass through.

input=$(cat)
prompt=$(jq -r .prompt <<< "$input")

case "$prompt" in
  x)
    if [[ -n "$CODEX_EXIT_SESSION_FILE" ]]; then
      jq -r .session_id <<< "$input" > "$CODEX_EXIT_SESSION_FILE"
    fi
    (sleep 0.1; pkill -INT -x codex 2>/dev/null) &
    echo "Exiting..." >&2
    exit 2
    ;;
esac
