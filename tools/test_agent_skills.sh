#!/bin/bash
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/agent-skills.sh
source "$REPO_DIR/tools/agent-skills.sh"
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
AI_SKILL_ROOT="$REPO_DIR/skills"

for agent in claude agents; do
  skill_home="$task_dir/$agent/skills"
  GH_BRIDGE_URL='' configure_host_skills "$skill_home"
  test ! -e "$skill_home/gh-host"
  GH_BRIDGE_URL=https://host.example configure_host_skills "$skill_home"
  test -L "$skill_home/gh-host"
  cmp "$AI_SKILL_ROOT/gh-host/SKILL.md" "$skill_home/gh-host/SKILL.md"
  GH_BRIDGE_URL=https://host.example configure_host_skills "$skill_home"
  test ! -e "$skill_home/gh-host/gh-host"
  GH_BRIDGE_URL='' configure_host_skills "$skill_home"
  test ! -L "$skill_home/gh-host"

  mkdir -p "$skill_home/gh-host"
  printf '%s\n' 'User skill' > "$skill_home/gh-host/SKILL.md"
  GH_BRIDGE_URL=https://host.example configure_host_skills "$skill_home" 2>/dev/null
  GH_BRIDGE_URL='' configure_host_skills "$skill_home"
  test "$(cat "$skill_home/gh-host/SKILL.md")" = 'User skill'
done

echo 'at=info msg="agent host skill lifecycle tests passed"'

# Verify the wrappers expose the skill before handing control to either agent.
mkdir -p "$task_dir/bin" "$task_dir/settings/codex" "$task_dir/home"
printf '%s\n' '{}' > "$task_dir/settings/codex/auth.json"
printf '%s\n' '{}' > "$task_dir/claude-settings.json"
cat > "$task_dir/bin/start.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
for agent in claude codex; do
  cat > "$task_dir/bin/$agent" <<'STUB'
#!/bin/sh
case "${0##*/}" in
  claude) skill_home="$HOME/.claude/skills" ;;
  codex) skill_home="$HOME/.agents/skills" ;;
esac
if [ -n "${GH_BRIDGE_URL:-}" ]; then
  cmp "$AI_SKILL_ROOT/gh-host/SKILL.md" "$skill_home/gh-host/SKILL.md"
else
  test ! -e "$skill_home/gh-host"
fi
STUB
  chmod +x "$task_dir/bin/$agent"
done
chmod +x "$task_dir/bin/start.sh"
for bridge_url in https://host.example ''; do
  for agent in claude codex; do
    arguments=()
    if [[ "$agent" == claude ]]; then arguments=(--apikey test); fi
    HOME="$task_dir/home" HISTORY_ROOT="$task_dir/history" \
    SETTINGS_ROOT="$task_dir/settings" CLAUDE_SETTINGS_FILE="$task_dir/claude-settings.json" \
    PLUGIN_ROOT="$task_dir/no-plugins" CODEX_PLUGIN_ROOT="$task_dir/no-plugins" \
    PLUGIN_BLOCKLIST="$task_dir/no-blocklist" AI_SKILL_ROOT="$AI_SKILL_ROOT" \
    GH_BRIDGE_URL="$bridge_url" PATH="$task_dir/bin:$PATH" \
      bash "$REPO_DIR/tools/$agent.sh" "${arguments[@]}"
  done
done

echo 'at=info msg="agent host skill launch tests passed"'
