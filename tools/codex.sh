#!/bin/bash

set -e

history_dir () {
  local tool=$1
  local year=$(date +%Y)
  local month=$(date +%m_%b)
  local day_time=$(date +%d_%a_%H-%M)
  echo "/history/${year}/${month}/${day_time}_${tool}"
}

shared_codex_home=/settings/codex
shared_auth="${shared_codex_home}/auth.json"

if [[ ! -f "$shared_auth" ]]; then
  echo "at=error msg=\"codex auth file not found\" path=$shared_auth"
  echo ""
  echo "  First time? Run codex-login to Sign in with Device Code."
  echo ""
  exit 1
fi

settings_home=$(history_dir codex)

rm -f $HOME/.codex # should be a symlink
mkdir -p $settings_home
ln -s $settings_home $HOME/.codex

install -m 600 "$shared_auth" "$HOME/.codex/auth.json"
[[ -f /settings/AGENTS.md ]] && cp /settings/AGENTS.md "$HOME/.codex"

# Pre-trust the working directory so codex skips the "Do you trust this
# directory?" prompt. The .codex home is recreated on each launch, so the
# trust answer is never persisted otherwise.
cat > $HOME/.codex/config.toml <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[projects."$PWD"]
trust_level = "trusted"
EOF

sync_auth_back() {
  local session_auth="$HOME/.codex/auth.json"
  [[ -s "$session_auth" ]] || return 0

  if ! install -m 600 "$session_auth" "$shared_auth"; then
    echo "at=warn msg=\"failed to sync codex auth back to settings\" path=$shared_auth" >&2
  fi
}

trap sync_auth_back EXIT

set +e
codex \
  --dangerously-bypass-approvals-and-sandbox \
  --search
status=$?
set -e

sync_auth_back
trap - EXIT
exit "$status"
