#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

assert_label() {
  local expected=$1

  if ! grep -Fx "agent=${expected}" "$PODMAN_ARGS_FILE" >/dev/null; then
    echo "at=fatal msg=\"agent label not found\" expected=\"$expected\"" >&2
    exit 1
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
ai_dir="${tmpdir}/ai"
mkdir -p "$fake_bin" "${ai_dir}/settings" "${tmpdir}/home"
cat > "${fake_bin}/podman" <<'EOF'
#!/bin/sh
if [ "$1" = ps ]; then
  printf '%s\n' "${EXISTING_CONTAINER_NAME:-}"
else
  printf '%s\n' "$@" > "$PODMAN_ARGS_FILE"
fi
EOF
chmod +x "${fake_bin}/podman"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"

HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" cx >/dev/null
assert_label codex
container_name=$(awk 'previous == "--name" { print; exit } { previous = $0 }' "$PODMAN_ARGS_FILE")
container_hostname=$(awk 'previous == "--hostname" { print; exit } { previous = $0 }' "$PODMAN_ARGS_FILE")
[[ "$container_name" == ai-c-00-* ]]
[[ "$container_hostname" == "$container_name" ]]
HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:$PATH" \
  EXISTING_CONTAINER_NAME="$container_name" "$REPO_DIR/bin/ai" cx >/dev/null
grep -Fx "ai-c-01-${container_name#ai-c-00-}" "$PODMAN_ARGS_FILE" >/dev/null
project_name=$(basename "$(pwd)")
grep -Fx "HOST_DIR=$project_name" "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx "$(pwd):/app" "$PODMAN_ARGS_FILE" >/dev/null
if grep -F '/host-workdir/' "$PODMAN_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="project was mounted at a second working directory"' >&2
  exit 1
fi

mkdir -p "${ai_dir}/settings/codex_alpha"
printf '{}\n' > "${ai_dir}/settings/codex_alpha/auth.json"
HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" cx alpha >/dev/null
grep -Fx 'CODEX_PROFILE=alpha' "$PODMAN_ARGS_FILE" >/dev/null

expires_at=$(( $(date +%s) * 1000 + 7200000 ))
jq -n --argjson expires_at "$expires_at" \
  '{claudeAiOauth: {expiresAt: $expires_at}}' \
  > "${ai_dir}/settings/.credentials.alpha.json"

HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" c alpha >/dev/null
assert_label claude

# Each spelling selects the same agent, profile, and resume environment.
for selector in c claude cx codex; do
  case "$selector" in
    c|claude) agent=claude; prefix=CLAUDE ;;
    cx|codex) agent=codex; prefix=CODEX ;;
  esac
  HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:$PATH" \
    "$REPO_DIR/bin/ai" "$selector" >/dev/null
  assert_label "$agent"
  grep -Fx "${prefix}_AUTO_START=1" "$PODMAN_ARGS_FILE" >/dev/null
  HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:$PATH" \
    "$REPO_DIR/bin/ai" --ports 9999 "$selector" alpha --resume session-id >/dev/null
  assert_label "$agent"
  grep -Fx "${prefix}_AUTO_START=1" "$PODMAN_ARGS_FILE" >/dev/null
  grep -Fx "${prefix}_PROFILE=alpha" "$PODMAN_ARGS_FILE" >/dev/null
  grep -Fx "${prefix}_RESUME=session-id" "$PODMAN_ARGS_FILE" >/dev/null
done

# Shell-only launches create a new container without auto-starting an agent.
for arguments in '' '--ports 9999'; do
  # Split the option string into arguments; an empty string passes none.
  # shellcheck disable=SC2086
  HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:$PATH" \
    "$REPO_DIR/bin/ai" $arguments >/dev/null
  assert_label ''
  grep -Fx 'run' "$PODMAN_ARGS_FILE" >/dev/null
  grep -Fx -- '--interactive' "$PODMAN_ARGS_FILE" >/dev/null
  if grep -E '^(CLAUDE|CODEX)_AUTO_START=' "$PODMAN_ARGS_FILE" >/dev/null; then
    echo 'at=fatal msg="shell-only launch auto-started an agent"' >&2
    exit 1
  fi
done

for arguments in '--resume session-id' alpha 'alpha c' 'c cx' 'codex claude' 'c c'; do
  rm -f "$PODMAN_ARGS_FILE"
  if HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:$PATH" \
    "$REPO_DIR/bin/ai" $arguments >"$tmpdir/error" 2>&1; then
    echo "at=fatal msg=\"invalid agent selection accepted\" args=\"$arguments\"" >&2
    exit 1
  fi
  test ! -e "$PODMAN_ARGS_FILE"
done

# Exercise the shell's auto-launch block without guest-specific setup.
cat > "$tmpdir/bashrc" <<'RC'
c() { printf 'claude\n' >> "$AGENT_CALLS_FILE"; }
cx() { printf 'codex\n' >> "$AGENT_CALLS_FILE"; }
start.sh() { :; }
RC
sed -n '/^auto_launch_requested=false/,$p' "$REPO_DIR/dot.bashrc" >> "$tmpdir/bashrc"
export AGENT_CALLS_FILE="$tmpdir/agent-calls"
for agent in CLAUDE CODEX; do
  env AI_AUTO_LAUNCH=1 "${agent}_AUTO_START=1" \
    bash --noprofile --rcfile "$tmpdir/bashrc" -ic \
    'test -z "${CLAUDE_AUTO_START:-}${CODEX_AUTO_START:-}" && source "$1"' \
    bash "$tmpdir/bashrc" >"$tmpdir/shell-output" 2>&1
done
printf 'claude\ncodex\n' > "$tmpdir/expected-calls"
diff -u "$tmpdir/expected-calls" "$AGENT_CALLS_FILE"

echo 'at=info msg="ai agent label tests passed"'
