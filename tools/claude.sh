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
  echo "Usage: $(basename "$0") <profile> [--resume <id>] | --apikey <key> [--resume <id>] | --resume <id>"
  echo
  echo "  <profile>            Use oauth credentials from /settings for the given profile"
  echo "  --apikey <key>       Use the provided Anthropic API key"
  echo "  -r, --resume <id>    Resume a prior session; profile is auto-detected if omitted."
  echo "                       <id> may be a prefix — the matching .jsonl under /history is located"
  echo "                       and ~/.claude is symlinked to its original home."
  exit 1
}

profile=""
apikey=""
resume_id=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --apikey)
      apikey="${2:?--apikey requires a value}"
      shift 2
      ;;
    -r|--resume)
      resume_id="${2:?--resume requires a session id}"
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

if [[ -n "$resume_id" ]]; then
  jsonl=$(find /history -path "*/projects/*/${resume_id}*.jsonl" -print 2>/dev/null | head -n 1)
  if [[ -z "$jsonl" ]]; then
    echo "No session matching '${resume_id}' found under /history" >&2
    exit 1
  fi
  resume_id=$(basename "$jsonl" .jsonl)
  # <claude-home>/projects/<slug>/<id>.jsonl → <claude-home>
  settings_claude_home=$(dirname "$(dirname "$(dirname "$jsonl")")")

  if [[ -z "$profile" && -z "$apikey" && -f "$settings_claude_home/.profile" ]]; then
    saved=$(cat "$settings_claude_home/.profile")
    [[ "$saved" != "apikey" ]] && profile="$saved"
  fi
else
  settings_claude_home=$(history_dir claude)
  mkdir -p "$settings_claude_home"
fi

if [[ -z "$profile" && -z "$apikey" ]]; then
  if [[ -n "$resume_id" ]]; then
    echo "Session '${resume_id}' was launched with --apikey; pass --apikey <key> to resume" >&2
    exit 1
  fi
  usage
fi

rm -f $HOME/.claude/.credentials.json
rm -f $HOME/.claude # should be a symlink
rm -f $HOME/.claude.json
rm -f $HOME/.claude.json.backup

ln -s "$settings_claude_home" $HOME/.claude

# oauth credentials
if [[ -n "$profile" ]]; then
  settings_credentials=/settings/.credentials.${profile}.json
  test -f $settings_credentials && cp -f $settings_credentials $HOME/.claude/.credentials.json
fi

[[ -f /settings/AGENTS.md ]]  && cp -f /settings/AGENTS.md  $HOME/.claude/CLAUDE.md

# claude/claude.json -> ~/.claude.json (preserve existing one when resuming)
if [[ -f /claude/claude.json ]]; then
  if [[ -z "$resume_id" || ! -f "$settings_claude_home/claude.json" ]]; then
    cp -f /claude/claude.json "$settings_claude_home/claude.json"
  fi
  ln -sf "$settings_claude_home/claude.json" $HOME/.claude.json
fi

# claude/settings.json -> ~/.claude/settings.json (via ~/.claude symlink)
if [[ -f /claude/settings.json ]]; then
  cp -f /claude/settings.json "$settings_claude_home/settings.json"
fi

echo "${profile:-apikey}" > $HOME/.claude/.profile

if [[ -n "$apikey" ]]; then
  export ANTHROPIC_API_KEY="$apikey"
fi

resume_flag=()
[[ -n "$resume_id" ]] && resume_flag=(--resume "$resume_id")

exec claude \
  --dangerously-skip-permissions \
  --model claude-opus-4-7 \
  --effort high \
  "${resume_flag[@]}"
