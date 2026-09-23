#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
ai_dir="${tmpdir}/ai"
mkdir -p "$fake_bin" "$ai_dir" "${tmpdir}/home"

cat > "${fake_bin}/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF

cat > "${fake_bin}/chrome-canary" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CHROME_ARGS_FILE"
for argument do
  case "$argument" in
    --user-data-dir=*) profile=${argument#--user-data-dir=} ;;
  esac
done
mkdir -p "$profile"
if [ -f "${profile}/persisted-state" ]; then
  printf '%s\n' reused > "$PROFILE_REUSED_FILE"
fi
printf '%s\n' persisted > "${profile}/persisted-state"
printf '9222\n/devtools/browser/test\n' > "${profile}/DevToolsActivePort"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF

cat > "${fake_bin}/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$PODMAN_ARGS_FILE"
EOF
cat > "${fake_bin}/ps" <<'EOF'
#!/bin/sh
if [ "${PROFILE_LOCK_ACTIVE:-0}" -eq 1 ]; then
  printf '%s\n' '/bin/sh /project/bin/ai --host-browser'
else
  exec /bin/ps "$@"
fi
EOF
chmod +x "${fake_bin}/uname" "${fake_bin}/chrome-canary" \
  "${fake_bin}/podman" "${fake_bin}/ps"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"
export CHROME_ARGS_FILE="${tmpdir}/chrome-args"
export PROFILE_REUSED_FILE="${tmpdir}/profile-reused"
output=$(
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --host-browser 2>&1
)

grep -F 'at=info msg="host browser ready" browser="Google Chrome Canary"' <<< "$output" >/dev/null
grep -Fx -- HOST_BROWSER_URL "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- HOST_BROWSER_TOKEN "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- HOST_BROWSER_CA "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- NODE_EXTRA_CA_CERTS "$PODMAN_ARGS_FILE" >/dev/null
grep -E '^.*/host-browser\.[^/]+/bridge:/run/host-browser:ro$' "$PODMAN_ARGS_FILE" >/dev/null
grep -F 'PassEnvironment=HOST_BROWSER_URL HOST_BROWSER_TOKEN HOST_BROWSER_CA NODE_EXTRA_CA_CERTS' \
  "$REPO_DIR/Dockerfile" >/dev/null
grep -Fx -- --no-startup-window "$CHROME_ARGS_FILE" >/dev/null
grep -Fx -- "--user-data-dir=${ai_dir}/host-browser/profile" \
  "$CHROME_ARGS_FILE" >/dev/null
if grep -Fx -- about:blank "$CHROME_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="host browser opened a foreground startup page"' >&2
  exit 1
fi

if grep -E '^HOST_BROWSER_TOKEN=' "$PODMAN_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="host browser token was exposed in podman arguments"' >&2
  exit 1
fi
if find "${ai_dir}/run" -mindepth 1 -print -quit | grep . >/dev/null; then
  echo 'at=fatal msg="host browser session directory was not removed"' >&2
  exit 1
fi
test -f "${ai_dir}/host-browser/profile/persisted-state"

mkdir "${ai_dir}/host-browser/profile.lock"
printf '%s\n' 999999 > "${ai_dir}/host-browser/profile.lock/owner"
HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --host-browser >/dev/null 2>&1
test -f "$PROFILE_REUSED_FILE"

named_reused_file="${tmpdir}/named-profile-reused"
HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
PROFILE_REUSED_FILE="$named_reused_file" \
PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --host-browser=work >/dev/null 2>&1
grep -Fx -- "--user-data-dir=${ai_dir}/host-browser/profiles/work" \
  "$CHROME_ARGS_FILE" >/dev/null
test -f "${ai_dir}/host-browser/profiles/work/persisted-state"
test ! -f "$named_reused_file"
HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
PROFILE_REUSED_FILE="$named_reused_file" \
PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --host-browser=work >/dev/null 2>&1
test -f "$named_reused_file"

if HOME="${tmpdir}/home" AI_DIR="$ai_dir" \
  AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --host-browser=../bad >/dev/null 2>&1; then
  echo 'at=fatal msg="invalid host browser profile was accepted"' >&2
  exit 1
fi

mkdir "${ai_dir}/host-browser/profile.lock"
printf '%s\n' 123 > "${ai_dir}/host-browser/profile.lock/owner"
lock_output="${tmpdir}/lock-output"
if HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
  PROFILE_LOCK_ACTIVE=1 \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --host-browser >"$lock_output" 2>&1; then
  echo 'at=fatal msg="concurrent host browser profile use was allowed"' >&2
  exit 1
fi
grep -F 'host browser profile is already in use' "$lock_output" >/dev/null
grep -Fx 123 "${ai_dir}/host-browser/profile.lock/owner" >/dev/null

echo 'at=info msg="host browser launcher tests passed"'
