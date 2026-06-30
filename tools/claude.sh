#!/bin/bash

set -e

HISTORY_ROOT=${HISTORY_ROOT:-/history}

is_true () {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Merge a jq assignment into the session's settings.json, creating it if
# missing. Used by the per-session --remote / --fast opt-ins.
enable_setting () {
  local file=$1
  local filter=$2
  local tmp
  [[ -f "$file" ]] || echo '{}' > "$file"
  tmp=$(mktemp)
  jq "$filter" "$file" > "$tmp"
  mv "$tmp" "$file"
}

history_dir () {
  local tool=$1
  local year
  local month
  local day_time

  year=$(date +%Y)
  month=$(date +%m_%b)
  day_time=$(date +%d_%a_%H-%M)

  echo "${HISTORY_ROOT}/${year}/${month}/${day_time}_${tool}"
}

find_resume_jsonl () {
  local history_root=$1
  local session_id=$2
  local match
  local projects_dir

  case "$session_id" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
  esac

  while IFS= read -r projects_dir; do
    [[ -n "$projects_dir" ]] || continue

    match=$(
      find "$projects_dir" -mindepth 2 -maxdepth 2 -type f \
        -name "${session_id}*.jsonl" -print -quit 2>/dev/null
    )
    if [[ -n "$match" ]]; then
      printf '%s\n' "$match"
      return 0
    fi
  done <<EOF
$(find "$history_root" -maxdepth 4 -type d -path "*_claude/projects" -print 2>/dev/null)
EOF

  return 1
}

usage () {
  echo "Usage: $(basename "$0") <profile> [--resume <id>] [--debug[=filter]] | --apikey <key> [...] | --resume <id> [...]"
  echo
  echo "  <profile>            Use oauth credentials from /settings for the given profile"
  echo "  --apikey <key>       Use the provided Anthropic API key"
  echo "  -r, --resume <id>    Resume a prior session; profile is auto-detected if omitted."
  echo "                       <id> may be a prefix — the matching .jsonl under /history is located"
  echo "                       and ~/.claude is symlinked to its original home."
  echo "  -d, --debug          Pass --debug to claude."
  echo "      --debug=<filter> Pass --debug <filter> to claude (e.g. --debug=api,hooks)."
  echo "      --remote         Enable Claude Code remote control for this session."
  echo "                       Also enabled when AI_REMOTE is truthy (1/true/yes/on)."
  echo "      --fast           Enable fast mode for this session."
  echo "                       Also enabled when AI_FAST is truthy (1/true/yes/on)."
  exit 1
}

main () {
  local profile=""
  local apikey=""
  local remote="${AI_REMOTE:-}"
  local fast="${AI_FAST:-}"
  local resume_id=""
  local jsonl=""
  local saved
  local settings_claude_home
  local settings_file
  local settings_credentials
  local sentry_token
  local sentry_host
  local tmp
  local -a debug_flag=()
  local -a resume_flag=()

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
      -d|--debug)
        debug_flag=(--debug)
        shift
        ;;
      --debug=*)
        debug_flag=(--debug "${1#--debug=}")
        shift
        ;;
      --remote)
        remote=1
        shift
        ;;
      --fast)
        fast=1
        shift
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
    if ! jsonl=$(find_resume_jsonl "$HISTORY_ROOT" "$resume_id"); then
      echo "No session matching '${resume_id}' found under ${HISTORY_ROOT}" >&2
      exit 1
    fi
    resume_id=$(basename "$jsonl" .jsonl)
    # <claude-home>/projects/<slug>/<id>.jsonl -> <claude-home>
    settings_claude_home=$(dirname "$(dirname "$(dirname "$jsonl")")")

    if [[ -z "$profile" && -z "$apikey" && -f "$settings_claude_home/.profile" ]]; then
      saved=$(cat "$settings_claude_home/.profile")
      [[ "$saved" != "apikey" ]] && profile="$saved"
    fi
  else
    settings_claude_home=$(history_dir claude)
    mkdir -p "$settings_claude_home"
    # Sidecar session name: the host directory.
    # The viewer falls back to this when Claude hasn't generated its own summary.
    if [[ -n "${HOST_DIR:-}" ]]; then
      printf '%s\n' "$HOST_DIR" > "$settings_claude_home/.session_name"
    fi
  fi

  if [[ -z "$profile" && -z "$apikey" ]]; then
    if [[ -n "$resume_id" ]]; then
      echo "Session '${resume_id}' was launched with --apikey; pass --apikey <key> to resume" >&2
      exit 1
    fi
    usage
  fi

  # Bring up services (postgres, lavinmq, redis) and run bundle install.
  # Don't let a service hiccup block claude from starting.
  start.sh || true

  rm -f "$HOME/.claude/.credentials.json"
  rm -f "$HOME/.claude" # should be a symlink
  rm -f "$HOME/.claude.json"
  rm -f "$HOME/.claude.json.backup"

  ln -s "$settings_claude_home" "$HOME/.claude"

  # oauth credentials
  if [[ -n "$profile" ]]; then
    settings_credentials=/settings/.credentials.${profile}.json
    test -f "$settings_credentials" && cp -f "$settings_credentials" "$HOME/.claude/.credentials.json"
  fi

  [[ -f /settings/AGENTS.md ]] && cp -f /settings/AGENTS.md "$HOME/.claude/CLAUDE.md"

  # claude/claude.json -> ~/.claude.json (preserve existing one when resuming)
  if [[ -f /claude/claude.json ]]; then
    if [[ -z "$resume_id" || ! -f "$settings_claude_home/claude.json" ]]; then
      cp -f /claude/claude.json "$settings_claude_home/claude.json"
    fi
    ln -sf "$settings_claude_home/claude.json" "$HOME/.claude.json"
  fi

  # /settings/sentry.token -> enable Sentry MCP via local stdio server.
  # The hosted mcp.sentry.dev uses an OAuth callback to localhost which can't
  # work from inside a container, so we run @sentry/mcp-server locally instead.
  # Optional companion file: /settings/sentry.host (e.g. sentry.io or self-hosted).
  if [[ -f /settings/sentry.token && -f "$settings_claude_home/claude.json" ]]; then
    sentry_token=$(tr -d '[:space:]' < /settings/sentry.token)
    sentry_host=""
    [[ -f /settings/sentry.host ]] && sentry_host=$(tr -d '[:space:]' < /settings/sentry.host)
    tmp=$(mktemp)
    jq --arg token "$sentry_token" --arg host "$sentry_host" '.mcpServers.sentry = {
      "type": "stdio",
      "command": "npx",
      "args": (
        ["-y", "@sentry/mcp-server@latest"]
        + (if $host != "" then ["--host=" + $host] else [] end)
      ),
      "env": {"SENTRY_ACCESS_TOKEN": $token}
    }' "$settings_claude_home/claude.json" > "$tmp"
    mv "$tmp" "$settings_claude_home/claude.json"
  fi

  # claude/settings.json -> ~/.claude/settings.json (via ~/.claude symlink)
  if [[ -f /claude/settings.json ]]; then
    cp -f /claude/settings.json "$settings_claude_home/settings.json"
  fi

  settings_file="$settings_claude_home/settings.json"

  # Opt-in Claude Code remote control (--remote or AI_REMOTE truthy). Off by
  # default: it exposes this session to claude.ai/the mobile app behind only
  # your login. Sets the key the `/config` "Enable Remote Control for all
  # sessions" toggle writes; the bridge then starts automatically each session.
  is_true "$remote" && enable_setting "$settings_file" '.remoteControlAtStartup = true'

  # Opt-in fast mode (--fast or AI_FAST truthy). Off by default: it draws from
  # usage credits at a higher rate with separate rate limits. Needs Opus 4.6+,
  # which the launch model below satisfies.
  #
  # The persisted setting is evaluated once at startup while the async fast-mode
  # availability check is still "pending", so in a fresh container it resolves
  # to off and never re-applies. Skip that check (the org/availability gate) so
  # the setting engages immediately.
  if is_true "$fast"; then
    enable_setting "$settings_file" '.fastMode = true'
    export CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1
  fi

  echo "${profile:-apikey}" > "$HOME/.claude/.profile"

  if [[ -n "$apikey" ]]; then
    export ANTHROPIC_API_KEY="$apikey"
  fi

  [[ -n "$resume_id" ]] && resume_flag=(--resume "$resume_id")

  # Label remote-control sessions by the host directory rather than the
  # container hostname, so they're legible in the claude.ai/mobile session
  # list (shows as "<HOST_DIR>-<random-words>"). Only remote control reads it.
  if [[ -n "${HOST_DIR:-}" ]]; then
    export CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX="$HOST_DIR"
  fi

  exec claude \
    --dangerously-skip-permissions \
    --model claude-opus-4-8 \
    --effort xhigh \
    "${resume_flag[@]}" \
    "${debug_flag[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
