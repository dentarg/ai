#!/bin/sh

# Shared agent-version pin updates used by both image builders.

update_claude_version () {
  version=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
      echo "at=fatal msg=\"invalid Claude Code version\" version=\"$version\"" >&2
      exit 1
      ;;
  esac
  mkdir -p "$REPO_DIR/versions"
  printf '%s\n' "$version" > "$REPO_DIR/versions/claude-code"
}

update_codex_version () {
  if ! command -v jq >/dev/null 2>&1; then
    echo 'at=fatal msg="jq is required to update Codex version pin"' >&2
    exit 1
  fi

  version=$(curl -fsSL https://registry.npmjs.org/@openai/codex/latest | jq -r .version)
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
      echo "at=fatal msg=\"invalid Codex version\" version=\"$version\"" >&2
      exit 1
      ;;
  esac
  mkdir -p "$REPO_DIR/versions"
  printf '%s\n' "$version" > "$REPO_DIR/versions/codex"
}

update_plugin_manifest () {
  file=$1
  tmp=$(mktemp)

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        printf '%s\n' "$line" >> "$tmp"
        continue
        ;;
    esac

    # shellcheck disable=SC2086 # deliberate word splitting into name/url/commit
    set -- $line
    if [ "$#" -ne 3 ]; then
      echo "at=fatal msg=\"invalid plugin pin\" file=\"$file\" line=\"$line\"" >&2
      rm -f "$tmp"
      exit 1
    fi

    sha=$(git ls-remote "$2" HEAD | cut -f1)
    case "$sha" in
      ????????????????????????????????????????) ;;
      *)
        echo "at=fatal msg=\"invalid plugin commit\" name=\"$1\" url=\"$2\" sha=\"$sha\"" >&2
        rm -f "$tmp"
        exit 1
        ;;
    esac

    printf '%s  %s  %s\n' "$1" "$2" "$sha" >> "$tmp"
  done < "$file"

  mv "$tmp" "$file"
}

update_plugins_versions () {
  update_plugin_manifest "$REPO_DIR/versions/claude-plugins"
  update_plugin_manifest "$REPO_DIR/versions/codex-plugins"
}
