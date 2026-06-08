#!/bin/bash

set -e

history_dir () {
  local tool=$1
  local year
  local month
  local day_time

  year=$(date +%Y)
  month=$(date +%m_%b)
  day_time=$(date +%d_%a_%H-%M)

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

rm -f "$HOME/.codex" # should be a symlink
mkdir -p "$settings_home"
ln -s "$settings_home" "$HOME/.codex"

install -m 600 "$shared_auth" "$HOME/.codex/auth.json"
[[ -f /settings/AGENTS.md ]] && cp /settings/AGENTS.md "$HOME/.codex"

host_dir="${HOST_DIR:-$(basename "$PWD")}"
case "$host_dir" in
  ""|*/*) host_dir=$(basename "$PWD") ;;
esac

codex_cwd="$PWD"
host_workdir_parent=""
if host_workdir_parent=$(mktemp -d /tmp/codex-host-cwd.XXXXXX); then
  host_workdir="$host_workdir_parent/$host_dir"
  if ln -s "$PWD" "$host_workdir"; then
    codex_cwd="$host_workdir"
  else
    echo "at=warn msg=\"failed to create host-named codex cwd\" path=$host_workdir" >&2
    rmdir "$host_workdir_parent" 2>/dev/null || true
    host_workdir_parent=""
  fi
else
  echo "at=warn msg=\"failed to create temporary codex cwd parent\"" >&2
fi

pwd_toml=$(printf '%s' "$PWD" | jq -Rs .)
codex_cwd_toml=$(printf '%s' "$codex_cwd" | jq -Rs .)

# Pre-trust the working directory so codex skips the "Do you trust this
# directory?" prompt. The .codex home is recreated on each launch, so the
# trust answer is never persisted otherwise.
cat > "$HOME/.codex/config.toml" <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[tui]
status_line = ["project-name", "git-branch", "model-with-reasoning", "context-used", "thread-id"]
terminal_title = ["project-name"]

[projects.$pwd_toml]
trust_level = "trusted"
EOF

if [[ "$codex_cwd" != "$PWD" ]]; then
  cat >> "$HOME/.codex/config.toml" <<EOF

[projects.$codex_cwd_toml]
trust_level = "trusted"
EOF
fi

sync_auth_back() {
  local session_auth="$HOME/.codex/auth.json"
  [[ -s "$session_auth" ]] || return 0

  if ! install -m 600 "$session_auth" "$shared_auth"; then
    echo "at=warn msg=\"failed to sync codex auth back to settings\" path=$shared_auth" >&2
  fi
}

cleanup() {
  sync_auth_back
  if [[ -n "$host_workdir_parent" ]]; then
    rm -rf "$host_workdir_parent"
  fi
}

trap 'cleanup' EXIT

set +e
codex \
  --cd "$codex_cwd" \
  --dangerously-bypass-approvals-and-sandbox \
  --search
status=$?
set -e

cleanup
trap - EXIT
exit "$status"
