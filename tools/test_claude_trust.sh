#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/claude.sh
source "${SCRIPT_DIR}/claude.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/shared"
ln -s "$tmpdir/shared" "$tmpdir/app"
resolved=$(cd "$tmpdir/shared" && pwd -P)
claude_json="$tmpdir/claude.json"

jq -n --arg app "$tmpdir/app" \
  '{projects: {($app): {hasTrustDialogAccepted: true}}}' > "$claude_json"
trust_resolved_app "$claude_json" "$tmpdir/app"
jq -e --arg resolved "$resolved" \
  '.projects[$resolved].hasTrustDialogAccepted == true' "$claude_json" >/dev/null

# A directory that is not a symlink keeps its single entry.
jq -n --arg app "$resolved" \
  '{projects: {($app): {hasTrustDialogAccepted: true}}}' > "$claude_json"
trust_resolved_app "$claude_json" "$resolved"
jq -e '.projects | length == 1' "$claude_json" >/dev/null

echo 'at=info msg="Claude trust tests passed"'
