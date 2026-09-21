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
printf '9222\n/devtools/browser/test\n' > "${profile}/DevToolsActivePort"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF

cat > "${fake_bin}/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$PODMAN_ARGS_FILE"
EOF
chmod +x "${fake_bin}/uname" "${fake_bin}/chrome-canary" "${fake_bin}/podman"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"
export CHROME_ARGS_FILE="${tmpdir}/chrome-args"
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

echo 'at=info msg="host browser launcher tests passed"'
