#!/bin/bash

set -e

history_dir () {
  local tool=$1
  local year=$(date +%Y)
  local month=$(date +%m_%b)
  local day_time=$(date +%d_%a_%H-%M)
  echo "/history/${year}/${month}/${day_time}_${tool}"
}

usage () {
  echo "Usage: $(basename "$0") <profile> | --apikey <key>"
  echo
  echo "  <profile>       Use oauth credentials from /settings for the given profile"
  echo "  --apikey <key>  Use the provided Anthropic API key"
  exit 1
}

profile=""
apikey=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --apikey)
      apikey="${2:?--apikey requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      profile="$1"
      shift
      ;;
  esac
done

if [[ -z "$profile" && -z "$apikey" ]]; then
  usage
fi

settings_claude_home=$(history_dir claude)

rm -f $HOME/.claude/.credentials.json
rm -f $HOME/.claude # should be a symlink
rm -f $HOME/.claude.json
rm -f $HOME/.claude.json.backup

mkdir -p $settings_claude_home
ln -s $settings_claude_home $HOME/.claude

# oauth credentials
if [[ -n "$profile" ]]; then
  settings_credentials=/settings/.credentials.${profile}.json
  test -f $settings_credentials && cp -f $settings_credentials $HOME/.claude/.credentials.json
fi

[[ -f /settings/AGENTS.md ]]  && cp -f /settings/AGENTS.md  $HOME/.claude/CLAUDE.md

# claude/claude.json -> ~/.claude.json
if [[ -f /claude/claude.json ]]; then
  cp -f /claude/claude.json $settings_claude_home/claude.json
  ln -sf $settings_claude_home/claude.json $HOME/.claude.json
fi

# claude/settings.json -> ~/.claude/settings.json (via ~/.claude symlink)
if [[ -f /claude/settings.json ]]; then
  cp -f /claude/settings.json $settings_claude_home/settings.json
fi

echo "${profile:-apikey}" > $HOME/.claude/.profile

if [[ -n "$apikey" ]]; then
  export ANTHROPIC_API_KEY="$apikey"
fi

exec claude \
  --dangerously-skip-permissions \
  --model claude-opus-4-6 \
  --effort high
