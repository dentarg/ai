#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
ai_dir="${tmpdir}/ai"
mkdir -p "$fake_bin" "$ai_dir" "${tmpdir}/home"

printf '#!/bin/sh\necho Darwin\n' > "${fake_bin}/uname"
printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/op"
printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/osascript"
# Keep the variable literal for the fake executable to expand at runtime.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$PODMAN_ARGS_FILE"\n' \
  > "${fake_bin}/podman"
chmod +x "${fake_bin}/uname" \
         "${fake_bin}/op" \
         "${fake_bin}/osascript" \
         "${fake_bin}/podman"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"
export HOME="${tmpdir}/home" AI_DIR="$ai_dir"
mkdir "$tmpdir/unrelated-checkout"
for config_home in "${tmpdir}/custom config" '' relative; do
  export XDG_CONFIG_HOME="$config_home"
  "$REPO_DIR/bin/1password-bridge" init example.1password.com >/dev/null
  (
    cd "$tmpdir/unrelated-checkout"
    PATH="${fake_bin}:${PATH}" \
      "$REPO_DIR/bin/ai" c --1password >/dev/null
  )
done
unset XDG_CONFIG_HOME
"$REPO_DIR/bin/1password-bridge" init example.1password.com >/dev/null
PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" c --1password >/dev/null

if grep -F '/.config/ai' "$PODMAN_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="host configuration was mounted into the container"' >&2
  exit 1
fi

grep -Fx -- "OP_BRIDGE_URL" "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- "OP_BRIDGE_TOKEN" "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- "OP_BRIDGE_CA" "$PODMAN_ARGS_FILE" >/dev/null
grep -E '^.*/onepassword\.[^:]+:/run/1password-bridge:ro$' "$PODMAN_ARGS_FILE" >/dev/null

if grep -E '^OP_BRIDGE_TOKEN=' "$PODMAN_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="1Password bridge token was exposed in podman arguments"' >&2
  exit 1
fi

echo 'at=info msg="1Password bridge launcher tests passed"'
