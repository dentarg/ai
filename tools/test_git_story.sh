#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
tmpdir=$(cd "$tmpdir" && pwd -P)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/repo with spaces" "$tmpdir/not-a-repo"
export GIT_STORY_TEST_LOG="$tmpdir/podman.log"
export AI_DIR="$tmpdir/state"
export PATH="$tmpdir/bin:$PATH"
cat > "$tmpdir/bin/podman" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$GIT_STORY_TEST_LOG"
printf '%s\n' '{"result":"ok"}'
exit "${GIT_STORY_TEST_EXIT:-0}"
EOF
chmod +x "$tmpdir/bin/podman"

assert_arg() {
  grep -Fx -- "<$1>" "$GIT_STORY_TEST_LOG" >/dev/null
}

# Help must work without a repository or a container runtime.
cd "$tmpdir/not-a-repo"
"$REPO_DIR/bin/git-story" > "$tmpdir/help"
grep -F 'Usage: git-story DIRECTORY' "$tmpdir/help" >/dev/null
test ! -e "$GIT_STORY_TEST_LOG"

git init --quiet "$tmpdir/repo with spaces"
cd "$tmpdir/repo with spaces"
repo_dir=$(pwd -P)
PORT=3210 GIT_HISTORY_UI_TOKEN=test-password \
  "$REPO_DIR/bin/git-story" . --author 'Jane Doe' > "$tmpdir/output" 2> "$tmpdir/errors"
assert_arg "$repo_dir:$repo_dir:ro"
assert_arg "$AI_DIR/git-history-ui:/workspace/.git-history-ui"
assert_arg "$repo_dir"
assert_arg '127.0.0.1:3210:1337'
assert_arg 'GHUI_LLM_PROVIDER=heuristic'
assert_arg 'Jane Doe'
assert_arg 'SIGTERM'
assert_arg 'ai:latest'
assert_arg 'exec git-history-ui "$@"'
grep -F 'Open http://127.0.0.1:3210' "$tmpdir/errors" >/dev/null
grep -F 'Password: test-password' "$tmpdir/errors" >/dev/null

# Reports preserve arguments, stdout, and exit status, with no listening port.
"$REPO_DIR/bin/git-story" . pr-impact --base main --head 'feature/report' \
  --format json > "$tmpdir/output" 2> "$tmpdir/errors"
assert_arg pr-impact
assert_arg feature/report
test "$(cat "$tmpdir/output")" = '{"result":"ok"}'
test ! -s "$tmpdir/errors"
if grep -F -- '<--publish>' "$GIT_STORY_TEST_LOG"; then
  echo 'CLI subcommand published a port' >&2
  exit 1
fi
status=0
GIT_STORY_TEST_EXIT=7 "$REPO_DIR/bin/git-story" . wrapped --json >/dev/null || status=$?
test "$status" -eq 7

# Linked worktrees retain access to their shared Git directory, read-only.
git -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null commit --quiet --allow-empty -m fixture
git worktree add --quiet --detach "$tmpdir/worktree"
"$REPO_DIR/bin/git-story" "$tmpdir/worktree" wrapped --json >/dev/null
assert_arg "$repo_dir/.git:$repo_dir/.git:ro"

# Invalid input fails before invoking Podman.
rm "$GIT_STORY_TEST_LOG"
for port in invalid 0 65536; do
  if PORT="$port" "$REPO_DIR/bin/git-story" . >/dev/null 2>&1; then
    echo "Accepted invalid PORT: $port" >&2
    exit 1
  fi
done
for directory in "$tmpdir/missing" "$tmpdir/not-a-repo"; do
  if "$REPO_DIR/bin/git-story" "$directory" >/dev/null 2>&1; then
    echo "Accepted invalid repository: $directory" >&2
    exit 1
  fi
done
test ! -e "$GIT_STORY_TEST_LOG"

echo 'at=info msg="git-story tests passed"'
