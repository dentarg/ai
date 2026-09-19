#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${SCRIPT_DIR}/claude-permission-hook.sh"

actual=$(
  jq -n '{hook_event_name: "PermissionRequest", tool_name: "Bash"}' |
    bash "$HOOK"
)

jq -e '
  .hookSpecificOutput.hookEventName == "PermissionRequest" and
  .hookSpecificOutput.decision.behavior == "allow"
' <<< "$actual" >/dev/null

actual=$(
  jq -n '{hook_event_name: "PermissionRequest", tool_name: "Edit"}' |
    bash "$HOOK"
)

if [[ -n "$actual" ]]; then
  echo 'at=fatal msg="permission hook approved a non-Bash request"' >&2
  exit 1
fi

echo 'at=info msg="claude permission hook tests passed"'
