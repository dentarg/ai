#!/bin/bash

set -e

profile="${1:-$(cat "$HOME/.claude/.profile" 2>/dev/null)}"

if [[ -z "$profile" || "$profile" = "apikey" ]]; then
  echo "at=error msg=\"no oauth profile to login with\""
  exit 1
fi

src="/settings/.credentials.${profile}.json"

if [[ ! -f "$src" ]]; then
  echo "at=error msg=\"credentials file not found\" path=$src"
  exit 1
fi

cp -f "$src" "$HOME/.claude/.credentials.json"
echo "Login refreshed (profile: $profile)"
