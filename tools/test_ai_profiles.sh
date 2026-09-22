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
  profile set-model alpha codex gpt-6-sol >/dev/null
grep -Fx 'model = "gpt-6-sol"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null
grep -Fx 'model_reasoning_effort = "high"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex gpt-6-astra >/dev/null
test "$(grep -c '^model = ' \
  "${ai_dir}/settings/codex_alpha/default.config.toml")" -eq 1
grep -Fx 'model = "gpt-6-astra"' \
  "${ai_dir}/settings/codex_alpha/default.config.toml" >/dev/null

printf '%s\n' '{"effortLevel":"high"}' > \
  "${ai_dir}/settings/claude_alpha/settings.json"
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha claude claude-opus-4-8 >/dev/null
jq -e '.model == "claude-opus-4-8" and .effortLevel == "high"' \
  "${ai_dir}/settings/claude_alpha/settings.json" >/dev/null

if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex '' >/dev/null 2>&1; then
  echo 'at=fatal msg="an empty model was accepted"' >&2
  exit 1
fi

output=$(AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile list)
printf '%s\n' "$output" | grep -E '^alpha[[:space:]]' >/dev/null
printf '%s\n' "$output" | grep -F 'gpt-6-astra' >/dev/null
printf '%s\n' "$output" | grep -F 'claude-opus-4-8' >/dev/null

printf '%s\n' '{}' > "${ai_dir}/settings/.credentials.alpha.json"
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile remove alpha >/dev/null
test ! -e "${ai_dir}/settings/codex_alpha"
test ! -e "${ai_dir}/settings/claude_alpha"
test ! -e "${ai_dir}/settings/.credentials.alpha.json"
if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile list | \
  grep -E '^alpha[[:space:]]' >/dev/null; then
  echo 'at=fatal msg="removed profile was listed"' >&2
  exit 1
fi

if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" profile create 'bad/name' \
  >/dev/null 2>&1; then
  echo 'at=fatal msg="profile creation accepted an invalid name"' >&2
  exit 1
fi

echo 'at=info msg="ai profile management tests passed"'
