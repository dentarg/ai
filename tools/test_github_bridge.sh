#!/bin/bash
set -euo pipefail
# Tests fake HOME; a BASH_ENV startup file could reset it to the real one.
unset BASH_ENV
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
fake_bin="$task_dir/bin"
mkdir -p "$fake_bin" "$task_dir/home"
export HOME="$task_dir/home" AI_DIR="$task_dir/data" XDG_CONFIG_HOME="$task_dir/config"
export BRIDGE_TEST_REPO="$REPO_DIR" BRIDGE_TEST_ARGS="$task_dir/args"
cat > "$fake_bin/uname" <<'STUB'
#!/bin/sh
case "${1:-}" in -m) echo arm64 ;; *) echo Darwin ;; esac
STUB
cat > "$fake_bin/osascript" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$fake_bin/op" <<'STUB'
#!/bin/sh
[ "$1" = read ] && [ "$2" = --account ] && [ "$3" = my.1password.com ] && [ "$4" = op://Agent/GitHub/token ] || exit 1
printf '%s\n' github_test_credential
STUB
cat > "$fake_bin/gh" <<'STUB'
#!/bin/sh
[ "$GH_TOKEN" = github_test_credential ] || exit 1
[ "$HOME" = "$GH_CONFIG_DIR" ] || exit 1
[ -z "${GH_DEBUG:-}" ] || exit 1
[ "$1" = api ] && [ "$2" = --hostname ] && [ "$3" = github.com ] || exit 1
case " $* " in
  *' --slurp '*) printf '%s\n' '[[{"number":12}]]' ;;
  *) printf '%s\n' '{"number":12}' ;;
esac
STUB
cat > "$fake_bin/podman" <<'STUB'
#!/bin/sh
[ "$1" != ps ] || exit 0
printf '%s\n' "$@" > "$BRIDGE_TEST_ARGS"
port=$(cat "$GH_BRIDGE_SESSION_DIR/bridge/port")
for operation in pr-comments pr-reviews pr-review-comments issue-list issue-view issue-comments issue-timeline; do
  set -- "$operation" owner/repo
  [ "$operation" = issue-list ] || set -- "$@" 12
  GH_BRIDGE_URL="https://127.0.0.1:$port" \
  GH_BRIDGE_CA="$GH_BRIDGE_SESSION_DIR/bridge/ca.pem" \
    "$BRIDGE_TEST_REPO/tools/gh-host.sh" "$@" >/dev/null || exit 1
done
GH_BRIDGE_URL="https://127.0.0.1:$port" \
GH_BRIDGE_CA="$GH_BRIDGE_SESSION_DIR/bridge/ca.pem" \
  "$BRIDGE_TEST_REPO/tools/gh-host.sh" pr-view owner/repo 12
STUB
chmod +x "$fake_bin/"*
"$REPO_DIR/bin/github-bridge" init work my.1password.com op://Agent/GitHub/token 'owner/*' >/dev/null
# The same host policy must work outside the directory where it was created.
mkdir "$task_dir/unrelated-checkout"
cd "$task_dir/unrelated-checkout"
if PATH="$fake_bin:$PATH" "$REPO_DIR/bin/ai" c --github=missing >/dev/null 2>&1; then
  echo 'at=fatal msg="unknown GitHub profile was accepted"' >&2
  exit 1
fi
output=$(GH_DEBUG=api PATH="$fake_bin:$PATH" "$REPO_DIR/bin/ai" c --github=work)
[[ "$output" == '{"number":12}' ]]
grep -Fx GH_BRIDGE_TOKEN "$BRIDGE_TEST_ARGS" >/dev/null
grep -E '/github\.[^/]+/bridge:/run/github-bridge:ro$' "$BRIDGE_TEST_ARGS" >/dev/null
if grep -E 'github_test_credential|GH_BRIDGE_TOKEN=|github-bridge.json|github-command-' "$BRIDGE_TEST_ARGS" "$AI_DIR/logs/github-bridge.log"; then
  echo 'at=fatal msg="GitHub bridge leaked host-only information"' >&2
  exit 1
fi
if find "$AI_DIR/run" -mindepth 1 -print -quit | grep .; then
  echo 'at=fatal msg="GitHub bridge session was not cleaned up"' >&2
  exit 1
fi
echo 'at=info msg="GitHub bridge launcher tests passed"'

cat > "$fake_bin/ssh" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$fake_bin/limactl" <<'STUB'
#!/bin/bash
printf '<%s>' "$@" >> "$BRIDGE_TEST_ARGS"
printf '\n' >> "$BRIDGE_TEST_ARGS"
case "$1" in
  list)
    case "$*" in
      *VMType*) echo vz ;;
      *SSHConfigFile*) echo /unused/ssh-config ;;
      *Dir*) echo /unused/vm ;;
      *) printf '%s\n' ai-base ai-base-macos ;;
    esac
    ;;
  shell)
    case "$*" in
      *'cat > /workspace/.ai-gh-token'*)
        received=$(cat)
        [ "$received" = "$GH_BRIDGE_TOKEN" ] || exit 1
        ;;
      *'tic -x'*) cat >/dev/null ;;
      *AI_AUTO_LAUNCH=1*)
        # Exercise the client using a token file, as the VM does.
        token_file="$GH_BRIDGE_SESSION_DIR/test-token"
        printf '%s' "$GH_BRIDGE_TOKEN" > "$token_file"
        port=$(cat "$GH_BRIDGE_SESSION_DIR/bridge/port")
        GH_BRIDGE_TOKEN='' GH_BRIDGE_TOKEN_FILE="$token_file" \
        GH_BRIDGE_URL="https://127.0.0.1:$port" \
        GH_BRIDGE_CA="$GH_BRIDGE_SESSION_DIR/bridge/ca.pem" \
          "$BRIDGE_TEST_REPO/tools/gh-host.sh" pr-view owner/repo 12
        ;;
    esac
    ;;
esac
STUB
chmod +x "$fake_bin/ssh" "$fake_bin/limactl"
for backend in --vm --macos; do
  : > "$BRIDGE_TEST_ARGS"
  PATH="$fake_bin:$PATH" AI_VM_HOST_PORT=45555 \
    "$REPO_DIR/bin/ai" cx "$backend" --github=work >/dev/null
  grep -F 'GH_BRIDGE_TOKEN_FILE=/workspace/.ai-gh-token' "$BRIDGE_TEST_ARGS" >/dev/null
  grep -F 'rm -f /workspace/.ai-gh-token' "$BRIDGE_TEST_ARGS" >/dev/null
  grep -F '/run/github-bridge' "$BRIDGE_TEST_ARGS" >/dev/null
  if grep -E 'GH_BRIDGE_TOKEN=|github_test_credential|github-bridge.json|github-command-' "$BRIDGE_TEST_ARGS"; then
    echo 'at=fatal msg="GitHub bridge leaked host-only information into Lima arguments"' >&2
    exit 1
  fi
  if find "$AI_DIR/run" -mindepth 1 -print -quit | grep .; then
    echo 'at=fatal msg="GitHub bridge VM session was not cleaned up"' >&2
    exit 1
  fi
done
echo 'at=info msg="GitHub bridge Lima tests passed"'
