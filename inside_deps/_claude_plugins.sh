#!/bin/bash
#
# Bake Claude Code plugin marketplaces into the image.
#
# Clones every marketplace pinned in versions/claude-plugins and symlinks each
# plugin it declares with an in-repo source into <dest>/enabled/. tools/claude.sh
# links whatever lands there into the session's ~/.claude/skills/, where Claude
# Code auto-loads it as <name>@skills-dir.
#
# Usage: _claude_plugins.sh <manifest> <dest>

set -euo pipefail

manifest=${1:?usage: $0 <manifest> <dest>}
dest=${2:?usage: $0 <manifest> <dest>}
claude=${CLAUDE_BIN:-$HOME/.local/bin/claude}

mkdir -p "$dest/marketplaces" "$dest/enabled"

# Strip comments; blank lines fall out as an empty $name below.
while read -r name url commit extra; do
  [[ -n "${name:-}" ]] || continue

  if [[ -z "${url:-}" || -z "${commit:-}" || -n "${extra:-}" ]]; then
    echo "$manifest: expected '<name> <git url> <commit>', got: $name ${url:-} ${commit:-} ${extra:-}" >&2
    exit 1
  fi

  repo="$dest/marketplaces/$name"
  echo "==> $name ${commit:0:12} ($url)"

  git clone --quiet "$url" "$repo"
  git -C "$repo" checkout --quiet --detach "$commit"
  rm -rf "$repo/.git"

  # Quiet unless it actually fails — a large marketplace emits a warning per
  # plugin and would bury everything else in the build log.
  if ! validation=$("$claude" plugin validate "$repo" 2>&1); then
    printf '%s\n' "$validation" >&2
    exit 1
  fi

  exposed=0
  remote=0
  missing=0
  while IFS=$'\t' read -r plugin source; do
    # Sources that aren't an in-repo path (another git repo, a URL) would need
    # fetching per plugin; leave those to their own entry in the manifest.
    if [[ -z "$source" || "$source" != ./* ]]; then
      remote=$((remote + 1))
      continue
    fi

    # A marketplace can declare a plugin whose directory isn't actually in the
    # repo. Say so and carry on rather than failing the whole image build.
    dir="$repo/${source#./}"
    if [[ ! -f "$dir/.claude-plugin/plugin.json" ]]; then
      echo "    warning: '$plugin' declares source '$source' but no plugin manifest is there" >&2
      missing=$((missing + 1))
      continue
    fi

    link="$dest/enabled/$plugin"
    if [[ -e "$link" ]]; then
      echo "$name: plugin name '$plugin' is already provided by $(readlink "$link")" >&2
      exit 1
    fi

    ln -s "$dir" "$link"
    exposed=$((exposed + 1))
  done < <(jq -r '
    .plugins[]
    | [.name, (if (.source | type) == "string" then .source else "" end)]
    | @tsv
  ' "$repo/.claude-plugin/marketplace.json")

  echo "    $exposed exposed, $remote skipped (non-local source), $missing skipped (not in repo)"
done < <(sed 's/#.*//' "$manifest")

echo
echo "Plugins available to every session:"
ls -1 "$dest/enabled" | sed 's/^/  /'
