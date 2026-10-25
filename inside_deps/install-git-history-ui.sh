#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
revision=$(cat "${1:?revision file is required}")
destination=${2:-/opt/git-history-ui}
bin_dir=${3:-/usr/local/bin}

if [[ ! $revision =~ ^[0-9a-f]{40}$ ]]; then
  echo 'at=fatal msg="git-history-ui requires a full commit SHA"' >&2
  exit 1
fi

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
git init --quiet "$build_dir"
git -C "$build_dir" fetch --quiet --depth 1 \
  https://github.com/beingmartinbmc/git-history-ui.git "$revision"
git -C "$build_dir" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$build_dir" rev-parse HEAD)" = "$revision"

cd "$build_dir"
# Reviewed dependency fixes, with exact versions and integrity hashes.
git apply --unidiff-zero "$SCRIPT_DIR/git-history-ui-dependencies.patch"

# Skip lifecycle hooks; explicitly build only the SQLite addon and the app.
npm ci --ignore-scripts --no-audit --no-fund
npm --ignore-scripts --prefix node_modules/better-sqlite3 run build-release
npm ci --prefix frontend --ignore-scripts --no-audit --no-fund
NG_CLI_ANALYTICS=false npm --ignore-scripts run build
npm prune --omit=dev --ignore-scripts --no-audit --no-fund
node -e 'const DB = require("better-sqlite3"); new DB(":memory:").close()'
test -s build/frontend/index.html
node dist/cli.js --version

mkdir -p "$destination" "$bin_dir"
cp -R dist build node_modules scripts package.json package-lock.json LICENSE "$destination/"
printf '%s\n' "$revision" > "$destination/REVISION"
chmod +x "$destination/dist/cli.js"
ln -sf "$destination/dist/cli.js" "$bin_dir/git-history-ui"
