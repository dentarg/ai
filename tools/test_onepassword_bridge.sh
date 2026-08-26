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

project=$(pwd -P)
jq -n \
  --arg project "$project" \
  '{projects: {($project): {account: "example.1password.com", secrets: {token: "op://Agent/Test/token"}}}}' \
  > "${ai_dir}/1password-bridge.json"
chmod 600 "${ai_dir}/1password-bridge.json"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"
HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --1password >/dev/null

grep -Fx -- "OP_BRIDGE_URL" "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- "OP_BRIDGE_TOKEN" "$PODMAN_ARGS_FILE" >/dev/null
grep -Fx -- "OP_BRIDGE_CA" "$PODMAN_ARGS_FILE" >/dev/null
grep -E '^.*/onepassword\.[^:]+:/run/1password-bridge:ro$' "$PODMAN_ARGS_FILE" >/dev/null

if grep -E '^OP_BRIDGE_TOKEN=' "$PODMAN_ARGS_FILE" >/dev/null; then
  echo 'at=fatal msg="1Password bridge token was exposed in podman arguments"' >&2
  exit 1
fi

echo 'at=info msg="1Password bridge launcher tests passed"'
