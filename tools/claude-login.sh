#!/bin/bash

set -e

profile="${1:-$(cat "$HOME/.claude/.profile" 2>/dev/null)}"

if [[ -z "$profile" || "$profile" = "apikey" ]]; then
  echo "at=error msg=\"no oauth profile to login with\""
  exit 1
fi

credentials="$HOME/.claude/.credentials.json"
history_dir="${HISTORY_DIR:-/history}"

if command -v refresh-tokens >/dev/null 2>&1 && \
  HISTORY_DIR="$history_dir" \
    refresh-tokens --copy-active "$profile" "$credentials" \
      >/dev/null 2>&1; then
  echo "Login refreshed from history (profile: $profile)"
  exit 0
fi

settings_dir="${SETTINGS_DIR:-/settings}"
src="${settings_dir}/.credentials.${profile}.json"

if [[ ! -f "$src" ]]; then
  echo "at=error msg=\"credentials file not found\" path=$src"
  exit 1
fi

cp -f "$src" "$credentials"
echo "Login refreshed (profile: $profile)"
