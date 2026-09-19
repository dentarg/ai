#!/bin/bash

set -euo pipefail

jq '
  if .hook_event_name == "PermissionRequest" and .tool_name == "Bash" then
    {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: {
          behavior: "allow"
        }
      }
    }
  else
    empty
  end
'
