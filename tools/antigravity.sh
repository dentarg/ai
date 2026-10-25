#!/bin/bash

set -euo pipefail

# shellcheck source=tools/agent-skills.sh
source "$(dirname "${BASH_SOURCE[0]}")/agent-skills.sh"

SETTINGS_ROOT=${SETTINGS_ROOT:-/settings}
HISTORY_ROOT=${HISTORY_ROOT:-/history}

link_state_directory () {
  local source=$1 destination=$2 backup
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    backup=$(mktemp -d "${destination}-backup.XXXXXX")
    mv "$destination" "$backup/${destination##*/}"
    echo "Saved existing configuration to $backup/${destination##*/}" >&2
  else
    rm -f "$destination"
  fi
  ln -s "$source" "$destination"
}

profile=""
if [[ "${1:-}" == --profile ]]; then
  profile=${2:?--profile requires a name}
  shift 2
fi
case "$profile" in
  .|..|*[!A-Za-z0-9._-]*)
    echo 'Invalid Antigravity profile name.' >&2
    exit 1
    ;;
esac

state_name="antigravity${profile:+_$profile}"
settings_home="$SETTINGS_ROOT/$state_name"
history_home="$HISTORY_ROOT/$state_name"
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
umask 077
mkdir -p "$settings_home/keyring" "$history_home" "$config_home"
# Keep global configuration in settings; CLI state and fallback credentials
# share a persistent history directory.
if [[ ! -e "$settings_home/antigravity-cli" && ! -L "$settings_home/antigravity-cli" ]]; then
  ln -s "$history_home" "$settings_home/antigravity-cli"
fi
link_state_directory "$settings_home" "$HOME/.gemini"
# Antigravity also scopes keyring credentials using a file outside ~/.gemini.
link_state_directory "$settings_home/keyring" "$config_home/antigravity"
if [[ -f "$SETTINGS_ROOT/AGENTS.md" ]]; then
  cp "$SETTINGS_ROOT/AGENTS.md" "$settings_home/GEMINI.md"
fi
configure_host_skills "$settings_home/config/skills"

case "${1:-}" in
  agent|agents|changelog|help|install|mcp|mic-serve|models|plugin|plugins|remote-control|update)
    exec antigravity-cli "$@"
    ;;
  *) exec antigravity-cli --dangerously-skip-permissions "$@" ;;
esac
