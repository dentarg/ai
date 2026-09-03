#!/bin/bash
#
# Bake Codex plugin marketplaces into a reusable per-session cache.
#
# Usage: _codex_plugins.sh <manifest> <dest>

set -euo pipefail

manifest=${1:?usage: $0 <manifest> <dest>}
dest=${2:?usage: $0 <manifest> <dest>}
codex=${CODEX_BIN:-codex}

mkdir -p "$dest/marketplaces" "$dest/plugins/cache"
dest=$(cd "$dest" && pwd)
: > "$dest/config.toml"

exposed=0
while read -r name url commit extra; do
  [[ -n "${name:-}" ]] || continue

  if [[ -z "${url:-}" || -z "${commit:-}" || -n "${extra:-}" ]]; then
    echo "at=fatal msg=\"invalid Codex plugin pin\" manifest=\"$manifest\"" >&2
    exit 1
  fi

  repo="$dest/marketplaces/$name"
  echo "at=info msg=\"cloning Codex plugin marketplace\" name=\"$name\" commit=\"${commit:0:12}\""
  git clone --quiet "$url" "$repo"
  git -C "$repo" checkout --quiet --detach "$commit"
  rm -rf "$repo/.git"

  marketplace_manifest="$repo/.agents/plugins/marketplace.json"
  if ! marketplace=$(jq -er '.name' "$marketplace_manifest"); then
    echo "at=fatal msg=\"invalid Codex marketplace manifest\" path=\"$marketplace_manifest\"" >&2
    exit 1
  fi
  case "$marketplace" in
    ''|*[!A-Za-z0-9._-]*)
      echo "at=fatal msg=\"invalid Codex marketplace name\" name=\"$marketplace\"" >&2
      exit 1
      ;;
  esac
  if grep -F "[marketplaces.$marketplace]" "$dest/config.toml" >/dev/null; then
    echo "at=fatal msg=\"duplicate Codex marketplace\" name=\"$marketplace\"" >&2
    exit 1
  fi

  source_toml=$(printf '%s' "$repo" | jq -Rs .)
  cat >> "$dest/config.toml" <<EOF
[marketplaces.$marketplace]
source_type = "local"
source = $source_toml

EOF

  while IFS=$'\t' read -r plugin source_type source; do
    [[ -n "$plugin" ]] || continue
    if [[ "$source_type" != local || "$source" != ./* ]]; then
      echo "at=info msg=\"skipping non-local Codex plugin\" plugin=\"$plugin@$marketplace\""
      continue
    fi
    case "$plugin" in
      *[!A-Za-z0-9._-]*)
        echo "at=fatal msg=\"invalid Codex plugin name\" name=\"$plugin\"" >&2
        exit 1
        ;;
    esac

    plugin_dir=$(readlink -f "$repo/${source#./}")
    case "$plugin_dir" in
      "$repo"/*) ;;
      *)
        echo "at=fatal msg=\"Codex plugin escapes marketplace\" plugin=\"$plugin@$marketplace\"" >&2
        exit 1
        ;;
    esac
    plugin_manifest="$plugin_dir/.codex-plugin/plugin.json"
    version=$(jq -er '.version' "$plugin_manifest")
    case "$version" in
      ''|*/*)
        echo "at=fatal msg=\"invalid Codex plugin version\" plugin=\"$plugin@$marketplace\" version=\"$version\"" >&2
        exit 1
        ;;
    esac

    cache="$dest/plugins/cache/$marketplace/$plugin/$version"
    if [[ -e "$cache" ]]; then
      echo "at=fatal msg=\"duplicate Codex plugin\" plugin=\"$plugin@$marketplace\"" >&2
      exit 1
    fi
    mkdir -p "$cache"
    cp -a "$plugin_dir/." "$cache/"
    cat >> "$dest/config.toml" <<EOF
[plugins."$plugin@$marketplace"]
enabled = true

EOF
    exposed=$((exposed + 1))
  done < <(jq -r '
    .plugins[]
    | [.name, (.source.source // ""), (.source.path // "")]
    | @tsv
  ' "$marketplace_manifest")
done < <(sed 's/#.*//' "$manifest")

validation_log="$dest/.validation.log"
if ! plugin_list=$(CODEX_HOME="$dest" "$codex" plugin list --json 2>"$validation_log"); then
  cat "$validation_log" >&2
  exit 1
fi
rm -f "$validation_log"
installed=$(printf '%s' "$plugin_list" | jq '[.installed[] | select(.enabled)] | length')
if [[ "$installed" -ne "$exposed" ]]; then
  echo "at=fatal msg=\"Codex plugin validation failed\" expected=$exposed installed=$installed" >&2
  exit 1
fi
rm -rf "$dest/.tmp"

echo "at=info msg=\"Codex plugins baked\" count=$exposed"
