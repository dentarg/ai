#!/bin/bash

set -e

HISTORY_ROOT=${HISTORY_ROOT:-/history}
SETTINGS_ROOT=${SETTINGS_ROOT:-/settings}

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

codex_session_id () {
  local path=$1
  local base
  local from_meta=""

  base=$(basename "$path" .jsonl)
  if [[ "$base" =~ ([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    from_meta=$(
      jq -r 'select(.type == "session_meta") | .payload.id // .payload.session_id // empty' \
        "$path" 2>/dev/null | head -n 1 || true
    )
  fi
  [[ -n "$from_meta" ]] || return 1
  printf '%s\n' "$from_meta"
}

find_matching_codex_resume_jsonl () {
  local history_root=$1
  local session_id=$2
  local name_pattern=$3
  local sessions_dir
  local rollout
  local sid

  while IFS= read -r sessions_dir; do
    [[ -n "$sessions_dir" ]] || continue

    while IFS= read -r rollout; do
      [[ -n "$rollout" ]] || continue
      if ! sid=$(codex_session_id "$rollout"); then
        continue
      fi
      case "$sid" in
        "$session_id"*)
          printf '%s\n' "$rollout"
          return 0
          ;;
      esac
    done < <(find "$sessions_dir" -type f -name "$name_pattern" -print 2>/dev/null)
  done < <(find "$history_root" -maxdepth 4 -type d -path '*_codex/sessions' -print 2>/dev/null)

  return 1
}

find_codex_resume_jsonl () {
  local history_root=$1
  local session_id=$2
  local match

  case "$session_id" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
  esac

  if match=$(find_matching_codex_resume_jsonl "$history_root" "$session_id" "rollout-*${session_id}*.jsonl"); then
    printf '%s\n' "$match"
    return 0
  fi

  find_matching_codex_resume_jsonl "$history_root" "$session_id" 'rollout-*.jsonl'
}

codex_settings_home () {
  local profile=$1

  if [[ -n "$profile" ]]; then
    printf '%s/codex_%s\n' "$SETTINGS_ROOT" "$profile"
  else
    printf '%s/codex\n' "$SETTINGS_ROOT"
  fi
}

valid_profile () {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

usage () {
  echo "Usage: $(basename "$0") [<auth-profile>] [--profile <config-profile>] [--resume <id>]"
  echo
  echo "  <auth-profile>       Use auth from /settings/codex_<profile>/auth.json."
  echo "  -p, --profile <name> Layer <name>.config.toml from the auth profile."
  echo "  -r, --resume <id>    Resume a prior Codex session; <id> may be a prefix."
  echo "                       Profiles are auto-detected if omitted."
  exit 1
}

main () {
  local profile=""
  local config_profile=""
  local resume_id=""
  local jsonl=""
  local saved
  local settings_home
  local shared_codex_home
  local shared_auth
  local config_profile_path
  local host_dir
  local codex_cwd
  local project_cwd
  local host_workdir_parent=""
  local host_workdir
  local status_profile
  local status_workdir
  local status_workdir_parent
  local pwd_toml
  local project_cwd_toml
  local codex_cwd_toml
  local status
  local -a codex_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--profile)
        config_profile="${2:?--profile requires a name}"
        shift 2
        ;;
      --profile=*)
        config_profile="${1#--profile=}"
        [[ -n "$config_profile" ]] || {
          echo 'at=fatal msg="--profile requires a name"' >&2
          exit 1
        }
        shift
        ;;
      -r|--resume)
        resume_id="${2:?--resume requires a session id}"
        shift 2
        ;;
      --resume=*)
        resume_id="${1#--resume=}"
        [[ -n "$resume_id" ]] || {
          echo 'at=fatal msg="--resume requires a session id"' >&2
          exit 1
        }
        shift
        ;;
      -h|--help)
        usage
        ;;
      -*)
        echo "at=fatal msg=\"unknown option\" option=\"$1\"" >&2
        usage
        ;;
      *)
        if [[ -n "$profile" ]] || ! valid_profile "$1"; then
          echo "at=fatal msg=\"invalid codex profile\" profile=\"$1\"" >&2
          usage
        fi
        profile=$1
        shift
        ;;
    esac
  done

  if [[ -n "$config_profile" ]] && ! valid_profile "$config_profile"; then
    echo "at=fatal msg=\"invalid Codex config profile\" profile=\"$config_profile\"" >&2
    usage
  fi

  if [[ -n "$resume_id" ]]; then
    if ! jsonl=$(find_codex_resume_jsonl "$HISTORY_ROOT" "$resume_id"); then
      echo "at=fatal msg=\"no codex session matching resume id\" resume=\"$resume_id\" history=\"$HISTORY_ROOT\"" >&2
      exit 1
    fi
    settings_home=${jsonl%%/sessions/*}
    if ! resume_id=$(codex_session_id "$jsonl"); then
      echo "at=fatal msg=\"codex session id not found\" path=\"$jsonl\"" >&2
      exit 1
    fi
    if [[ -z "$profile" && -f "$settings_home/.profile" ]]; then
      saved=$(cat "$settings_home/.profile")
      if valid_profile "$saved"; then
        profile=$saved
      fi
    fi
    if [[ -z "$config_profile" && -f "$settings_home/.config_profile" ]]; then
      saved=$(cat "$settings_home/.config_profile")
      if valid_profile "$saved"; then
        config_profile=$saved
      fi
    fi
  else
    settings_home=$(history_dir codex)
  fi

  shared_codex_home=$(codex_settings_home "$profile")
  shared_auth="${shared_codex_home}/auth.json"
  config_profile_path="${shared_codex_home}/${config_profile}.config.toml"
  if [[ ! -f "$shared_auth" ]]; then
    echo "at=error msg=\"codex auth file not found\" path=$shared_auth"
    echo ""
    echo "  First time? Run codex-login ${profile} to Sign in with Device Code."
    echo ""
    exit 1
  fi
  if [[ -n "$config_profile" && ! -f "$config_profile_path" ]]; then
    echo "at=fatal msg=\"codex config profile not found\" path=\"$config_profile_path\"" >&2
    exit 1
  fi

  rm -f "$HOME/.codex" # should be a symlink
  mkdir -p "$settings_home"
  ln -s "$settings_home" "$HOME/.codex"

  install -m 600 "$shared_auth" "$HOME/.codex/auth.json"
  if [[ -n "$profile" ]]; then
    printf '%s\n' "$profile" > "$HOME/.codex/.profile"
  else
    rm -f "$HOME/.codex/.profile"
  fi
  if [[ -n "$config_profile" ]]; then
    install -m 600 "$config_profile_path" \
      "$HOME/.codex/${config_profile}.config.toml"
    printf '%s\n' "$config_profile" > "$HOME/.codex/.config_profile"
  else
    rm -f "$HOME/.codex/.config_profile"
  fi
  [[ -f "$SETTINGS_ROOT/AGENTS.md" ]] && cp "$SETTINGS_ROOT/AGENTS.md" "$HOME/.codex"

  host_dir="${HOST_DIR:-$(basename "$PWD")}"
  case "$host_dir" in
    ""|*/*) host_dir=$(basename "$PWD") ;;
  esac

  codex_cwd="$PWD"
  if [[ -n "${HOST_WORKDIR:-}" && -d "$HOST_WORKDIR" && \
    "$(basename "$HOST_WORKDIR")" == "$host_dir" ]]; then
    codex_cwd=$HOST_WORKDIR
  elif host_workdir_parent=$(mktemp -d /tmp/codex-host-cwd.XXXXXX); then
    host_workdir="$host_workdir_parent/$host_dir"
    if ln -s "$PWD" "$host_workdir"; then
      codex_cwd="$host_workdir"
    else
      echo "at=warn msg=\"failed to create host-named codex cwd\" path=$host_workdir" >&2
      rmdir "$host_workdir_parent" 2>/dev/null || true
      host_workdir_parent=""
    fi
  else
    echo "at=warn msg=\"failed to create temporary codex cwd parent\"" >&2
  fi

  project_cwd=$codex_cwd
  status_profile=${profile:-default}
  status_workdir_parent=$HOME
  status_workdir="${status_workdir_parent}/${host_dir} [${status_profile}]"
  if [[ -e "$status_workdir" && ! -L "$status_workdir" ]]; then
    status_workdir_parent="$HOME/.cx"
    status_workdir="${status_workdir_parent}/${host_dir} [${status_profile}]"
  fi
  mkdir -p "$status_workdir_parent"
  if [[ ! -e "$status_workdir" || -L "$status_workdir" ]]; then
    ln -sfn "$project_cwd" "$status_workdir"
    codex_cwd=$status_workdir
  else
    echo "at=warn msg=\"Codex status workdir already exists\" path=\"$status_workdir\"" >&2
  fi

  pwd_toml=$(printf '%s' "$PWD" | jq -Rs .)
  project_cwd_toml=$(printf '%s' "$project_cwd" | jq -Rs .)
  codex_cwd_toml=$(printf '%s' "$codex_cwd" | jq -Rs .)

  # Pre-trust the working directory so codex skips the "Do you trust this
  # directory?" prompt. The .codex home is recreated on each launch, so the
  # trust answer is never persisted otherwise.
  cat > "$HOME/.codex/config.toml" <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[tui]
notifications = false
status_line = ["current-dir", "git-branch", "model-with-reasoning", "context-used", "thread-id"]
terminal_title = ["project-name"]

[projects.$pwd_toml]
trust_level = "trusted"
EOF

  if [[ "$project_cwd" != "$PWD" ]]; then
    cat >> "$HOME/.codex/config.toml" <<EOF

[projects.$project_cwd_toml]
trust_level = "trusted"
EOF
  fi

  if [[ "$codex_cwd" != "$PWD" ]]; then
    cat >> "$HOME/.codex/config.toml" <<EOF

[projects.$codex_cwd_toml]
trust_level = "trusted"
EOF
  fi

  sync_auth_back() {
    local session_auth="$HOME/.codex/auth.json"
    [[ -s "$session_auth" ]] || return 0

    if ! install -m 600 "$session_auth" "$shared_auth"; then
      echo "at=warn msg=\"failed to sync codex auth back to settings\" path=$shared_auth" >&2
    fi
  }

  cleanup() {
    sync_auth_back
    if [[ -n "$host_workdir_parent" ]]; then
      rm -rf "$host_workdir_parent"
    fi
    if [[ -L "$status_workdir" ]]; then
      rm -f "$status_workdir"
      if [[ "$status_workdir_parent" != "$HOME" ]]; then
        rmdir "$status_workdir_parent" 2>/dev/null || true
      fi
    fi
  }

  trap 'cleanup' EXIT

  codex_cmd=(
    codex
  )
  [[ -n "$config_profile" ]] && codex_cmd+=(--profile "$config_profile")
  codex_cmd+=(
    --cd "$codex_cwd"
    --dangerously-bypass-approvals-and-sandbox
    --search
  )
  [[ -n "$resume_id" ]] && codex_cmd+=(resume "$resume_id")

  set +e
  "${codex_cmd[@]}"
  status=$?
  set -e

  cleanup
  trap - EXIT
  exit "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
