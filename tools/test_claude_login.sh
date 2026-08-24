#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

assert_equal() {
  local expected=$1
  local actual=$2
  local message=$3

  if [[ "$actual" != "$expected" ]]; then
    echo "at=fatal msg=\"${message}\" expected=\"${expected}\" actual=\"${actual}\"" >&2
    exit 1
  fi
}

write_credentials() {
  local path=$1
  local token=$2
  local expires_at=$3

  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg token "$token" \
    --argjson expires_at "$expires_at" \
    '{claudeAiOauth: {accessToken: $token, expiresAt: $expires_at}}' \
    > "$path"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home_dir="${tmpdir}/home"
history_dir="${tmpdir}/history"
settings_dir="${tmpdir}/settings"
session_dir="${history_dir}/2026/08_Aug/22_Sat_10-00_claude"
expires_at=$(( $(date +%s) * 1000 + 3600000 ))

mkdir -p "${home_dir}/.claude" "$session_dir"
printf '%s\n' alpha > "${session_dir}/.profile"
write_credentials "${session_dir}/.credentials.json" history "$expires_at"
write_credentials "${settings_dir}/.credentials.alpha.json" settings 0

HOME="$home_dir" \
HISTORY_DIR="$history_dir" \
SETTINGS_DIR="$settings_dir" \
PATH="${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/tools/claude-login.sh" alpha >/dev/null
assert_equal history \
  "$(jq -r '.claudeAiOauth.accessToken' "${home_dir}/.claude/.credentials.json")" \
  "claude login did not prefer active history credentials"

HOME="$home_dir" \
HISTORY_DIR="${tmpdir}/empty-history" \
SETTINGS_DIR="$settings_dir" \
PATH="${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/tools/claude-login.sh" alpha >/dev/null
assert_equal settings \
  "$(jq -r '.claudeAiOauth.accessToken' "${home_dir}/.claude/.credentials.json")" \
  "claude login did not fall back to settings credentials"

echo 'at=info msg="claude login tests passed"'
