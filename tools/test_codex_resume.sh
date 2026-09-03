#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/codex.sh
source "${SCRIPT_DIR}/codex.sh"

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

SETTINGS_ROOT="${tmpdir}/settings"
assert_equal "${SETTINGS_ROOT}/codex" "$(codex_settings_home "")" \
  "default Codex settings path is wrong"
assert_equal "${SETTINGS_ROOT}/codex_alpha" "$(codex_settings_home alpha)" \
  "profile Codex settings path is wrong"

session_id=11111111-2222-4333-8444-555555555555
legacy_id=legacy-session
run_dir="${tmpdir}/example_codex"
session_day_dir="${run_dir}/sessions/2026/06/08"
other_workspace_dir="${tmpdir}/example_claude/projects/example-workspace"
expected="${session_day_dir}/rollout-2026-06-08T10-00-00-${session_id}.jsonl"
legacy_expected="${session_day_dir}/rollout-${legacy_id}.jsonl"

mkdir -p "$session_day_dir"
mkdir -p "$other_workspace_dir"

printf '{}\n' > "${other_workspace_dir}/${session_id}.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$session_id" > "$expected"

actual=$(find_codex_resume_jsonl "$tmpdir" "$session_id")
assert_equal "$expected" "$actual" "resume lookup selected wrong transcript"

actual=$(find_codex_resume_jsonl "$tmpdir" "${session_id:0:8}")
assert_equal "$expected" "$actual" "resume prefix lookup selected wrong transcript"

printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$legacy_id" > "$legacy_expected"
actual=$(find_codex_resume_jsonl "$tmpdir" "legacy")
assert_equal "$legacy_expected" "$actual" "resume lookup did not use session metadata fallback"

actual=$(find_codex_resume_jsonl "$tmpdir" "missing" || true)
assert_equal "" "$actual" "resume lookup should fail when no Codex session matches"

printf '%s\n' alpha > "$run_dir/.profile"
mkdir -p "${SETTINGS_ROOT}/codex_alpha" "${tmpdir}/home" "${tmpdir}/bin"
printf '%s\n' '{"profile":"alpha"}' > "${SETTINGS_ROOT}/codex_alpha/auth.json"

cat > "${tmpdir}/bin/start.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${tmpdir}/bin/codex" <<'EOF'
#!/bin/sh
jq -r .profile "$HOME/.codex/auth.json"
cat "$HOME/.codex/.profile"
if [ -f "$HOME/.codex/.config_profile" ]; then
  cat "$HOME/.codex/.config_profile"
  cat "$HOME/.codex/$(cat "$HOME/.codex/.config_profile").config.toml"
fi
printf '%s\n' "$@"
EOF
chmod +x "${tmpdir}/bin/start.sh" "${tmpdir}/bin/codex"

output=$(
  HOME="${tmpdir}/home" \
  HISTORY_ROOT="$tmpdir" \
  SETTINGS_ROOT="$SETTINGS_ROOT" \
  PATH="${tmpdir}/bin:$PATH" \
    main --resume "${session_id:0:8}"
)
assert_equal "alpha" "$(printf '%s\n' "$output" | sed -n '1p')" \
  "resume did not load the saved Codex profile auth"
assert_equal "alpha" "$(printf '%s\n' "$output" | sed -n '2p')" \
  "resume did not preserve the saved Codex profile"

printf '%s\n' 'model = "gpt-test"' > "${SETTINGS_ROOT}/codex_alpha/work.config.toml"
output=$(
  HOME="${tmpdir}/home" \
  HOST_DIR=$(basename "$run_dir") \
  HOST_WORKDIR="$run_dir" \
  HISTORY_ROOT="$tmpdir" \
  SETTINGS_ROOT="$SETTINGS_ROOT" \
  PATH="${tmpdir}/bin:$PATH" \
    main alpha --profile work
)
assert_equal "work" "$(printf '%s\n' "$output" | sed -n '3p')" \
  "Codex config profile was not saved"
assert_equal 'model = "gpt-test"' "$(printf '%s\n' "$output" | sed -n '4p')" \
  "Codex config profile was not installed"
printf '%s\n' "$output" | grep -Fx -- '--profile' >/dev/null
printf '%s\n' "$output" | grep -Fx -- 'work' >/dev/null
printf '%s\n' "$output" | grep -Fx -- '--cd' >/dev/null
printf '%s\n' "$output" | grep -Fx -- "$run_dir" >/dev/null

echo 'at=info msg="codex resume lookup tests passed"'
