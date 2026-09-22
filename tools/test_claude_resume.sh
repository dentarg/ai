#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/claude.sh
source "${SCRIPT_DIR}/claude.sh"

assert_equal () {
  local expected=$1
  local actual=$2
  local message=$3

  if [[ "$actual" != "$expected" ]]; then
    echo "at=fatal msg=\"${message}\" expected=\"${expected}\" actual=\"${actual}\"" >&2
    exit 1
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

session_id=11111111-2222-4333-8444-555555555555
subagent_id=agent-a1111111111111111
run_dir="${tmpdir}/example_claude"
workspace_dir="${run_dir}/projects/example-workspace"
session_dir="${workspace_dir}/${session_id}"
other_workspace_dir="${tmpdir}/example_gemini/projects/example-workspace"
expected="${workspace_dir}/${session_id}.jsonl"

mkdir -p "$other_workspace_dir"
printf '{}\n' > "${other_workspace_dir}/${session_id}.jsonl"

mkdir -p "${session_dir}/subagents"
printf '{}\n' > "${session_dir}/subagents/${subagent_id}.jsonl"
printf '{}\n' > "$expected"

actual=$(find_resume_jsonl "$tmpdir" "$session_id")
assert_equal "$expected" "$actual" "resume lookup selected wrong transcript"

actual=$(find_resume_jsonl "$tmpdir" "${session_id:0:8}")
assert_equal "$expected" "$actual" "resume prefix lookup selected wrong transcript"

actual=$(find_resume_jsonl "$tmpdir" "$subagent_id" || true)
assert_equal "" "$actual" "resume lookup should ignore subagent transcripts"

base_settings="${tmpdir}/base-settings.json"
profile_settings="${tmpdir}/profile-settings.json"
merged_settings="${tmpdir}/merged-settings.json"
printf '%s\n' \
  '{"model":"opus","effortLevel":"xhigh","env":{"base":"yes"}}' \
  > "$base_settings"
printf '%s\n' '{"model":"sonnet","env":{"profile":"yes"}}' \
  > "$profile_settings"

install_claude_settings \
  "$base_settings" "$profile_settings" "$merged_settings"
assert_equal sonnet "$(jq -r .model "$merged_settings")" \
  "Claude profile did not override the base model"
assert_equal xhigh "$(jq -r .effortLevel "$merged_settings")" \
  "Claude profile discarded the base effort"
jq -e '.env == {"base":"yes","profile":"yes"}' \
  "$merged_settings" >/dev/null

printf '%s\n' '{invalid' > "$profile_settings"
if install_claude_settings \
  "$base_settings" "$profile_settings" "$merged_settings" 2>/dev/null; then
  echo 'at=fatal msg="invalid Claude profile settings were merged"' >&2
  exit 1
fi
assert_equal sonnet "$(jq -r .model "$merged_settings")" \
  "invalid Claude profile settings replaced the previous settings"

fake_bin="${tmpdir}/bin"
home_dir="${tmpdir}/home"
settings_root="${tmpdir}/settings"
captured_settings="${tmpdir}/captured-settings.json"
captured_args="${tmpdir}/captured-args"
mkdir -p "$fake_bin" "$home_dir" "${settings_root}/claude_alpha"
printf '%s\n' '{"model":"sonnet"}' > \
  "${settings_root}/claude_alpha/settings.json"
cat > "${fake_bin}/start.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${fake_bin}/claude" <<'EOF'
#!/bin/sh
cp "$HOME/.claude/settings.json" "$CLAUDE_TEST_SETTINGS"
printf '%s\n' "$@" > "$CLAUDE_TEST_ARGS"
EOF
chmod +x "${fake_bin}/start.sh" "${fake_bin}/claude"

HOME="$home_dir" \
HISTORY_ROOT="${tmpdir}/launch-history" \
SETTINGS_ROOT="$settings_root" \
CLAUDE_SETTINGS_FILE="$base_settings" \
CLAUDE_TEST_SETTINGS="$captured_settings" \
CLAUDE_TEST_ARGS="$captured_args" \
PLUGIN_ROOT="${tmpdir}/plugins" \
PLUGIN_BLOCKLIST="${tmpdir}/plugins.blocklist" \
PATH="${fake_bin}:$PATH" \
  bash -c 'source "$1"; main alpha' _ "${SCRIPT_DIR}/claude.sh"
assert_equal sonnet "$(jq -r .model "$captured_settings")" \
  "Claude launch did not load profile settings"
assert_equal xhigh "$(jq -r .effortLevel "$captured_settings")" \
  "Claude launch did not retain base settings"
if grep -Eq '^--(model|effort)$' "$captured_args"; then
  echo 'at=fatal msg="Claude launch arguments override profile settings"' >&2
  exit 1
fi

echo 'at=info msg="claude resume lookup tests passed"'
