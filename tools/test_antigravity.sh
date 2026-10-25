#!/bin/bash

set -euo pipefail
[[ -z "${BASH_ENV:-}" ]] || exec env -u BASH_ENV bash "$0" "$@"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
mkdir -p "$task_dir/bin" "$task_dir/home/.gemini" "$task_dir/settings"
printf 'Gemini CLI state\n' > "$task_dir/home/.gemini/keep"
printf 'Shared instructions\n' > "$task_dir/settings/AGENTS.md"
cat > "$task_dir/bin/antigravity-cli" <<'STUB'
#!/bin/bash
set -eu
printf '%s\n' "$@" > "$TEST_ARGS"
readlink "$HOME/.gemini" > "$TEST_STATE"
cmp "$SETTINGS_ROOT/AGENTS.md" "$HOME/.gemini/GEMINI.md"
cmp "$AI_SKILL_ROOT/jactionlint/SKILL.md" "$HOME/.gemini/config/skills/jactionlint/SKILL.md"
printf 'Saved conversation\n' > "$HOME/.gemini/antigravity-cli/conversation"
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
test "$(readlink "$config_home/antigravity")" = "$(readlink "$HOME/.gemini")/keyring"
printf 'Credential scope\n' > "$config_home/antigravity/credential-user-scope"
exit "${TEST_EXIT_STATUS:-0}"
STUB
chmod +x "$task_dir/bin/antigravity-cli"
export HOME="$task_dir/home" SETTINGS_ROOT="$task_dir/settings"
export HISTORY_ROOT="$task_dir/history" AI_SKILL_ROOT="$REPO_DIR/skills"
export XDG_CONFIG_HOME="$task_dir/config"
export TEST_ARGS="$task_dir/args" TEST_STATE="$task_dir/state"
export PATH="$task_dir/bin:$PATH"

bash "$REPO_DIR/tools/antigravity.sh" --conversation session-id
printf '%s\n' --dangerously-skip-permissions --conversation session-id > "$task_dir/expected"
diff -u "$task_dir/expected" "$TEST_ARGS"
test "$(cat "$TEST_STATE")" = "$SETTINGS_ROOT/antigravity"
test "$(cat "$HISTORY_ROOT/antigravity/conversation")" = 'Saved conversation'
test -f "$SETTINGS_ROOT/antigravity/keyring/credential-user-scope"
backups=("$HOME"/.gemini-backup.*/.gemini/keep)
test "${#backups[@]}" -eq 1
test "$(cat "${backups[0]}")" = 'Gemini CLI state'

# Named profiles keep separate state and still expose native subcommands.
GH_BRIDGE_URL=https://host.example \
  bash "$REPO_DIR/tools/antigravity.sh" --profile work models
printf '%s\n' models > "$task_dir/expected"
diff -u "$task_dir/expected" "$TEST_ARGS"
test "$(cat "$TEST_STATE")" = "$SETTINGS_ROOT/antigravity_work"
test -f "$HISTORY_ROOT/antigravity_work/conversation"
test -f "$SETTINGS_ROOT/antigravity_work/keyring/credential-user-scope"
test -L "$SETTINGS_ROOT/antigravity_work/config/skills/gh-host"
bash "$REPO_DIR/tools/antigravity.sh" --profile work --continue
test ! -L "$SETTINGS_ROOT/antigravity_work/config/skills/gh-host"
test ! -e "$HISTORY_ROOT/antigravity_work/antigravity_work"

if bash "$REPO_DIR/tools/antigravity.sh" --profile ../other >/dev/null 2>&1; then
  echo 'Invalid profile was accepted.' >&2
  exit 1
fi
status=0
TEST_EXIT_STATUS=23 bash "$REPO_DIR/tools/antigravity.sh" --continue || status=$?
test "$status" -eq 23

export AI_DIR="$task_dir"
# shellcheck source=completions/ai.bash
source "$REPO_DIR/completions/ai.bash"
COMP_WORDS=(ai g w)
COMP_CWORD=2
_ai_complete
test "${COMPREPLY[*]}" = work
zsh -fc 'compdef() { :; }; source "$1"; _ai_antigravity_profiles' \
  zsh "$REPO_DIR/completions/_ai" > "$task_dir/profiles"
printf 'work\n' > "$task_dir/expected"
diff -u "$task_dir/expected" "$task_dir/profiles"

echo 'at=info msg="Antigravity launcher tests passed"'
