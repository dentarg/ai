#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

ai_dir="${tmpdir}/ai"

AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile create alpha >/dev/null

test -f "${ai_dir}/settings/codex_alpha/default.config.toml"
jq -e 'type == "object"' \
  "${ai_dir}/settings/claude_alpha/settings.json" >/dev/null

printf '%s\n' 'model_reasoning_effort = "high"' >> \
  "${ai_dir}/settings/codex_alpha/default.config.toml"
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex gpt-test >/dev/null
grep -Fx 'model = "gpt-test"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null
grep -Fx 'model_reasoning_effort = "high"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex gpt-replacement >/dev/null
test "$(grep -c '^model = ' \
  "${ai_dir}/settings/codex_alpha/default.config.toml")" -eq 1
grep -Fx 'model = "gpt-replacement"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null

printf '%s\n' '{"effortLevel":"high"}' > \
  "${ai_dir}/settings/claude_alpha/settings.json"
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha claude claude-test >/dev/null
jq -e '.model == "claude-test" and .effortLevel == "high"' \
  "${ai_dir}/settings/claude_alpha/settings.json" >/dev/null

if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex '' >/dev/null 2>&1; then
  echo 'at=fatal msg="an empty model was accepted"' >&2
  exit 1
fi

output=$(AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile list)
printf '%s\n' "$output" | grep -E '^alpha[[:space:]]' >/dev/null
printf '%s\n' "$output" | grep -F 'gpt-replacement' >/dev/null
printf '%s\n' "$output" | grep -F 'claude-test' >/dev/null

if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile create 'bad/name' \
  >/dev/null 2>&1; then
  echo 'at=fatal msg="profile creation accepted an invalid name"' >&2
  exit 1
fi

echo 'at=info msg="ai profile management tests passed"'
