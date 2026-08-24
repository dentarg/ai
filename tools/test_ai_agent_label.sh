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
# Keep the variables literal for the fake executable to expand at runtime.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$PODMAN_ARGS_FILE"\n' \
  > "${fake_bin}/podman"
chmod +x "${fake_bin}/podman"

export PODMAN_ARGS_FILE="${tmpdir}/podman-args"

HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" cx >/dev/null
assert_label codex

expires_at=$(( $(date +%s) * 1000 + 7200000 ))
jq -n --argjson expires_at "$expires_at" \
  '{claudeAiOauth: {expiresAt: $expires_at}}' \
  > "${ai_dir}/settings/.credentials.alpha.json"

HOME="${tmpdir}/home" \
AI_DIR="$ai_dir" \
PATH="${fake_bin}:${REPO_DIR}/bin:${PATH}" \
  "$REPO_DIR/bin/ai" alpha >/dev/null
assert_label claude

echo 'at=info msg="ai agent label tests passed"'
