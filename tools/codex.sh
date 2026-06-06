#!/bin/bash

set -e

history_dir () {
  local tool=$1
  local year=$(date +%Y)
  local month=$(date +%m_%b)
  local day_time=$(date +%d_%a_%H-%M)
  echo "/history/${year}/${month}/${day_time}_${tool}"
}

if [[ ! -d /settings/codex ]]; then
  echo "/settings/codex not found!"
  echo ""
  echo "  First time? You want to create /settings/codex/auth.json with OPENAI_API_KEY"
  echo ""
  exit 1
fi

settings_home=$(history_dir codex)

rm -f $HOME/.codex # should be a symlink
mkdir -p $settings_home
ln -s $settings_home $HOME/.codex

cp /settings/codex/auth.json $HOME/.codex
cp /settings/AGENTS.md       $HOME/.codex

# Pre-trust the working directory so codex skips the "Do you trust this
# directory?" prompt. The .codex home is recreated on each launch, so the
# trust answer is never persisted otherwise.
cat > $HOME/.codex/config.toml <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"

[projects."$PWD"]
trust_level = "trusted"
EOF

exec codex \
  --dangerously-bypass-approvals-and-sandbox \
  --search
