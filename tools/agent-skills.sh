#!/bin/bash

# Shared by the coding agent launchers.
configure_host_skills () {
  local skill_home=$1
  link_image_skill "$skill_home" jactionlint
  local source="${AI_SKILL_ROOT:-/opt/ai-skills}/gh-host"
  local destination="$skill_home/gh-host"

  if [[ -z "${GH_BRIDGE_URL:-}" ]]; then
    # Remove only our own link when resuming without the bridge.
    if [[ -L "$destination" && "$(readlink "$destination")" == "$source" ]]; then
      rm -f "$destination"
    fi
    return 0
  fi

  link_image_skill "$skill_home" gh-host
}

link_image_skill () {
  local skill_home=$1 name=$2
  local source="${AI_SKILL_ROOT:-/opt/ai-skills}/$name"
  local destination="$skill_home/$name"

  if [[ ! -f "$source/SKILL.md" ]]; then
    echo "at=warn msg=\"$name skill missing; rebuild the image or VM base\"" >&2
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" && "$(readlink "$destination")" == "$source" ]]; then
      return 0
    fi
    echo "at=warn msg=\"keeping existing $name skill\"" >&2
    return 0
  fi

  mkdir -p "$skill_home"
  ln -s "$source" "$destination"
}
