_ai_browser_profile_options() {
  local path
  printf '%s\n' --host-browser=default
  for path in "${AI_DIR:-${HOME}/ai}/host-browser/profiles"/*; do
    [[ -d "$path" ]] || continue
    printf '%s\n' "--host-browser=${path##*/}"
  done
}

_ai_complete() {
  local command=${COMP_WORDS[0]}
  local current=${COMP_WORDS[COMP_CWORD]}
  local first=${COMP_WORDS[1]:-}
  local action=${COMP_WORDS[2]:-}
  local agent=${COMP_WORDS[4]:-}
  local values=

  case "$COMP_CWORD" in
    1)
      values="profile models session completion c claude cx codex --resume --ports --udp-ports --vm
        --keep-vm --gpu --nested-virt --cpus --memory --1password
        --host-browser --remote --fast --help
        $(_ai_browser_profile_options)"
      ;;
    2)
      case "$first" in
        profile) values='list create remove set-model login --help' ;;
        models) values='list refresh --help' ;;
        session) values='start attach list stop logs replay ports invite invitations revoke join --help' ;;
        completion) values='bash zsh' ;;
        c|claude|cx|codex)
          values="$("$command" profile list 2>/dev/null | awk 'NR > 1 {print $1}')
            --resume --vm --keep-vm --gpu --nested-virt --cpus --memory
            --ports --udp-ports --1password --host-browser --help"
          case "$first" in c|claude) values="$values --remote --fast" ;; esac
          values="$values $(_ai_browser_profile_options)"
          ;;
      esac
      ;;
    3)
      case "$first:$action" in
        profile:create) values= ;;
        profile:remove|profile:set-model|profile:login)
          values=$("$command" profile list 2>/dev/null | awk 'NR > 1 {print $1}') ;;
        models:list) values='codex claude' ;;
      esac
      ;;
    4)
      case "$first:$action" in
        profile:set-model|profile:login) values='codex claude' ;;
      esac
      ;;
    5)
      if [[ "$first" == profile && "$action" == set-model ]]; then
        values=$("$command" models list "$agent" 2>/dev/null)
      fi
      ;;
  esac

  # Model and profile names cannot contain whitespace.
  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -W "$values" -- "$current"))
}

complete -F _ai_complete ai bin/ai ./bin/ai
