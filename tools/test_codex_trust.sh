#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/codex.sh
source "${SCRIPT_DIR}/codex.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/My Shared Files"
ln -s "$tmpdir/My Shared Files" "$tmpdir/app"
resolved=$(cd "$tmpdir/My Shared Files" && pwd -P)

trusted_projects_toml "$tmpdir/app" | python3 -c '
import sys, tomllib
projects = tomllib.loads(sys.stdin.read())["projects"]
assert sorted(projects) == sorted(sys.argv[1:]), projects
assert all(p["trust_level"] == "trusted" for p in projects.values())
' "$tmpdir/app" "$resolved"

# A directory that is not a symlink gets a single table.
trusted_projects_toml "$resolved" | python3 -c '
import sys, tomllib
assert list(tomllib.loads(sys.stdin.read())["projects"]) == sys.argv[1:]
' "$resolved"

echo 'at=info msg="Codex trust tests passed"'
