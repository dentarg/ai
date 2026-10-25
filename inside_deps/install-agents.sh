#!/bin/bash

set -euo pipefail

codex_version=${1:?Codex version is required}
claude_version=${2:?Claude Code version is required}
claude_installer=${3:?Claude installer path is required}
antigravity_manifest=${4:?Antigravity release manifest is required}
antigravity_installer=${5:?Antigravity installer path is required}

bash -c "npm install -g '@openai/codex@${codex_version}'"
bash "$claude_installer" "$claude_version"
bash "$antigravity_installer" "$antigravity_manifest"
# The native installer creates this cache/config directory during the build.
rm -rf "$HOME/.claude"
