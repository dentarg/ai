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
  local session_dir=$1
  local profile=$2
  local expires_at=$3
  local token=$4

  mkdir -p "$session_dir"
  printf '%s\n' "$profile" > "${session_dir}/.profile"
  jq -n \
    --arg token "$token" \
    --argjson expires_at "$expires_at" \
    '{claudeAiOauth: {accessToken: $token, expiresAt: $expires_at}}' \
    > "${session_dir}/.credentials.json"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

ai_dir="${tmpdir}/ai"
history_dir="${ai_dir}/history"
now_ms=$(( $(date +%s) * 1000 ))
older_expiry=$(( now_ms + 3600000 ))
newer_expiry=$(( now_ms + 7200000 ))
other_expiry=$(( now_ms + 5400000 ))
expired=$(( now_ms - 1000 ))

older_session="${history_dir}/2026/08_Aug/20_Thu_10-00_claude"
newer_session="${history_dir}/2026/08_Aug/20_Thu_11-00_claude"
other_session="${history_dir}/2026/08_Aug/20_Thu_12-00_claude"
expired_session="${history_dir}/2026/08_Aug/20_Thu_13-00_claude"

write_credentials "$older_session" alpha "$older_expiry" older
write_credentials "$newer_session" alpha "$newer_expiry" newer
write_credentials "$other_session" beta "$other_expiry" other
write_credentials "$expired_session" alpha "$expired" expired

list_output=$(HISTORY_DIR="$history_dir" \
  "$REPO_DIR/bin/refresh-tokens" --list-active)
assert_equal 3 "$(printf '%s\n' "$list_output" | tail -n +2 | wc -l | tr -d ' ')" \
  "active listing returned the wrong number of credentials"

profile_output=$(HISTORY_DIR="$history_dir" \
  "$REPO_DIR/bin/refresh-tokens" --list-active alpha)
assert_equal 2 "$(printf '%s\n' "$profile_output" | tail -n +2 | wc -l | tr -d ' ')" \
  "profile listing returned the wrong number of credentials"

freshest=$(HISTORY_DIR="$history_dir" \
  "$REPO_DIR/bin/refresh-tokens" --find-active alpha)
assert_equal "${newer_session}/.credentials.json" "$freshest" \
  "freshest lookup selected the wrong credentials"

destination="${tmpdir}/copied/.credentials.alpha.json"
mkdir -p "$(dirname "$destination")"
HISTORY_DIR="$history_dir" \
  "$REPO_DIR/bin/refresh-tokens" --copy-active alpha "$destination" \
  >/dev/null
assert_equal newer "$(jq -r '.claudeAiOauth.accessToken' "$destination")" \
  "credential copy used the wrong source"

fake_bin="${tmpdir}/bin"
mkdir -p "${ai_dir}/settings" "$fake_bin" "${tmpdir}/home"
cp "${expired_session}/.credentials.json" \
  "${ai_dir}/settings/.credentials.alpha.json"
printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/podman"
chmod +x "${fake_bin}/podman"

HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" alpha >/dev/null 2>&1
assert_equal newer \
  "$(jq -r '.claudeAiOauth.accessToken' "${ai_dir}/settings/.credentials.alpha.json")" \
  "bin/ai did not recover expired profile credentials from history"

echo 'at=info msg="refresh token history tests passed"'
