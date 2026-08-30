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
