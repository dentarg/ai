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

ln -s "$tmpdir" "$tmpdir/history-link"
actual=$(find_codex_resume_jsonl "$tmpdir/history-link" "$session_id" || true)
assert_equal "$tmpdir/history-link/${expected#"$tmpdir/"}" "$actual" \
  "resume lookup did not follow the macOS history root symlink"

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
if [ -f "$HOME/.codex/.profile" ]; then
  cat "$HOME/.codex/.profile"
fi
if [ -f "$HOME/.codex/.config_profile" ]; then
  cat "$HOME/.codex/.config_profile"
  cat "$HOME/.codex/$(cat "$HOME/.codex/.config_profile").config.toml"
fi
printf '%s\n' "$@"
EOF
chmod +x "${tmpdir}/bin/start.sh" "${tmpdir}/bin/codex"

mkdir -p "${tmpdir}/home/.codex/sessions"
printf '%s\n' 'existing local session' > "${tmpdir}/home/.codex/sessions/local.jsonl"

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
test -L "${tmpdir}/home/.codex"
assert_equal "$run_dir" "$(readlink "${tmpdir}/home/.codex")" \
  "resume did not link the selected session home"
backups=("${tmpdir}/home"/.codex-backup.*/.codex/sessions/local.jsonl)
assert_equal 1 "${#backups[@]}" "resume created multiple Codex home backups"
assert_equal 'existing local session' "$(cat "${backups[0]}")" \
  "resume did not preserve the existing Codex directory"

printf '%s\n' 'model = "gpt-test"' > "${SETTINGS_ROOT}/codex_alpha/work.config.toml"
output=$(
  cd "$run_dir"
  HOME="${tmpdir}/home" \
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
codex_cwd=$(printf '%s\n' "$output" | awk \
  'previous == "--cd" { print; exit } { previous = $0 }')
assert_equal "$run_dir" "$codex_cwd" \
  "Codex did not preserve the project working directory"
grep -F 'status_line = ["current-dir",' \
  "${tmpdir}/home/.codex/config.toml" >/dev/null

mkdir -p "${SETTINGS_ROOT}/codex"
printf '%s\n' '{"profile":"default"}' > "${SETTINGS_ROOT}/codex/auth.json"
printf '%s\n' 'model = "gpt-profile"' > \
  "${SETTINGS_ROOT}/codex/default.config.toml"
output=$(
  cd "$run_dir"
  HOME="${tmpdir}/home" \
  HISTORY_ROOT="$tmpdir" \
  SETTINGS_ROOT="$SETTINGS_ROOT" \
  PATH="${tmpdir}/bin:$PATH" \
    main
)
codex_cwd=$(printf '%s\n' "$output" | awk \
  'previous == "--cd" { print; exit } { previous = $0 }')
assert_equal "$run_dir" "$codex_cwd" \
  "default Codex launch did not preserve the project working directory"
assert_equal "default" "$(printf '%s\n' "$output" | sed -n '2p')" \
  "Codex default config profile was not selected"
assert_equal 'model = "gpt-profile"' "$(printf '%s\n' "$output" | sed -n '3p')" \
  "Codex default config profile was not installed"
grep -F 'model = "gpt-6-astra"' \
  "${tmpdir}/home/.codex/config.toml" >/dev/null

# Check container and VM titles through a terminal, including resumed sessions.
python3 - "$SCRIPT_DIR/codex.sh" "$tmpdir" "$session_id" <<'PYTHON'
import errno
import os
import pty
import subprocess
import sys
from pathlib import Path

wrapper, root, session_id = sys.argv[1:]
for hostname, arguments in (("ai-c-00-my-project", ["alpha"]),
                            ("ai-l-01-my-project", ["--resume", session_id])):
    hostname_command = Path(root, "bin", "hostname")
    hostname_command.write_text(f"#!/bin/sh\nprintf '%s\\n' '{hostname}'\n")
    hostname_command.chmod(0o755)
    env = dict(os.environ, HOME=f"{root}/home", HISTORY_ROOT=root,
               SETTINGS_ROOT=f"{root}/settings", HOST_DIR="my project\x1b\x07\n",
               TERM="xterm-256color", PATH=f"{root}/bin:{os.environ['PATH']}",
               CODEX_PLUGIN_ROOT=f"{root}/no-plugins")
    # A BASH_ENV startup file could reset HOME to the real home directory.
    env.pop("BASH_ENV", None)
    master, slave = pty.openpty()
    try:
        result = subprocess.run(["bash", wrapper, *arguments], env=env,
                                stdout=slave, stderr=subprocess.PIPE, timeout=10)
        result.check_returncode()
        os.close(slave)
        slave = None
        output = b""
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output += chunk
        expected = b"\x1b]0;my project [alpha] - Codex\x07"
        assert expected in output, repr(output)
        config = Path(root, "home", ".codex", "config.toml").read_text()
        assert 'terminal_title = []' in config, config
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)
PYTHON

# macOS shared mounts must not host SQLite's runtime files. Keep the
# transcript shared, but use a stable local database across repeated resumes.
cat > "${tmpdir}/bin/uname" <<'EOF'
#!/bin/sh
echo "${TEST_CODEX_OS:-Darwin}"
EOF
chmod +x "${tmpdir}/bin/uname"
printf '%s\n' 'shared database must remain untouched' > "$run_dir/state_5.sqlite"
previous_sqlite_home=""
for guest_os in Darwin Darwin Linux; do
  output=$(
    HOME="${tmpdir}/home" HISTORY_ROOT="$tmpdir" SETTINGS_ROOT="$SETTINGS_ROOT" \
    TEST_CODEX_OS="$guest_os" PATH="${tmpdir}/bin:$PATH" main --resume "$session_id"
  )
  sqlite_override=$(printf '%s\n' "$output" | sed -n 's/^sqlite_home=//p')
  if [[ "$guest_os" == Darwin ]]; then
    [[ -n "$sqlite_override" ]] || {
      echo 'at=fatal msg="macOS resume did not move SQLite off shared history"' >&2
      exit 1
    }
    sqlite_home=$(printf '%s' "$sqlite_override" | jq -r .)
    [[ "$sqlite_home" == "$tmpdir/home/.codex-state/"* ]]
    test -d "$sqlite_home"
    if [[ -n "$previous_sqlite_home" ]]; then
      assert_equal "$previous_sqlite_home" "$sqlite_home" "resume changed SQLite location"
    fi
    previous_sqlite_home=$sqlite_home
  else
    assert_equal "" "$sqlite_override" "Linux resume unexpectedly moved SQLite"
  fi
  assert_equal "$run_dir" "$(readlink "$tmpdir/home/.codex")" \
    "local SQLite changed the shared transcript location"
  assert_equal 'shared database must remain untouched' "$(cat "$run_dir/state_5.sqlite")" \
    "resume modified the shared database"
done

echo 'at=info msg="codex resume lookup tests passed"'
