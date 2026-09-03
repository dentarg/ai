#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

marketplace="${tmpdir}/marketplace"
plugin="${marketplace}/plugins/example"
mkdir -p "${marketplace}/.agents/plugins" "${plugin}/.codex-plugin" \
  "${plugin}/skills/example"

cat > "${marketplace}/.agents/plugins/marketplace.json" <<'EOF'
{
  "name": "example-marketplace",
  "plugins": [
    {
      "name": "example",
      "source": {
        "source": "local",
        "path": "./plugins/example"
      }
    }
  ]
}
EOF
cat > "${plugin}/.codex-plugin/plugin.json" <<'EOF'
{
  "name": "example",
  "version": "1.2.3",
  "description": "Test plugin",
  "skills": "./skills/"
}
EOF
cat > "${plugin}/skills/example/SKILL.md" <<'EOF'
---
name: example
description: Test skill.
---

# Example
EOF

git -C "$marketplace" init --quiet
git -C "$marketplace" add .
git -C "$marketplace" \
  -c user.name=Test -c user.email=test@example.com \
  commit --quiet -m fixture
commit=$(git -C "$marketplace" rev-parse HEAD)
printf 'example  %s  %s\n' "$marketplace" "$commit" \
  > "${tmpdir}/manifest"

CODEX_BIN=$(command -v codex) \
  bash "${REPO_DIR}/inside_deps/_codex_plugins.sh" \
    "${tmpdir}/manifest" "${tmpdir}/image-plugins"

grep -F '[marketplaces.example-marketplace]' \
  "${tmpdir}/image-plugins/config.toml" >/dev/null
grep -F '[plugins."example@example-marketplace"]' \
  "${tmpdir}/image-plugins/config.toml" >/dev/null
cache="${tmpdir}/image-plugins/plugins/cache/example-marketplace/example/1.2.3"
cached_skill="${cache}/skills/example/SKILL.md"
test -f "$cached_skill"

HOME="${tmpdir}/home"
mkdir -p "$HOME/.codex"
printf '%s\n' 'check_for_update_on_startup = false' \
  > "$HOME/.codex/config.toml"
CODEX_PLUGIN_ROOT="${tmpdir}/image-plugins"
# shellcheck source=tools/codex.sh
source "${REPO_DIR}/tools/codex.sh"
install_image_plugins

plugin_list=$(CODEX_HOME="$HOME/.codex" codex plugin list --json 2>/dev/null)
test "$(printf '%s' "$plugin_list" | jq -r '.installed[0].pluginId')" = \
  example@example-marketplace
test "$(printf '%s' "$plugin_list" | jq -r '.installed[0].enabled')" = true

echo 'at=info msg="Codex plugin tests passed"'
