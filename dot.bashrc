source /workspace/.bash_profile

# due to https://github.com/ruby/rubygems/issues/9124
export BUNDLE_DEFAULT_CLI_COMMAND=install
export BUNDLE_IGNORE_FUNDING_REQUESTS=1 # no post install messages will be printed
export BUNDLE_IGNORE_MESSAGES=1 # no funding requests will be printed
export BUNDLE_SILENCE_ROOT_WARNING=1
export HISTFILE=/commandhistory/.bash_history
# append to history file after each command
export PROMPT_COMMAND="history -a"
# allows claude to start with --dangerously-skip-permissions as root
export IS_SANDBOX=1
# our own tools
export PATH=$PATH:/usr/local/bin

# Claude Code
#
# Dynamic flavor text (AI-generated filler)
export DISABLE_NON_ESSENTIAL_MODEL_CALLS=1
# No "here's what happened while you were away" recap
export CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0

# the default is too low
ulimit -n 10480

# chruby
chruby_dir="${HOME}/chruby/share/chruby"
if [ -f $chruby_dir/chruby.sh ]; then
    . $chruby_dir/chruby.sh

    # Set RUBIES after chruby.sh (which initializes it as empty) but before
    # auto.sh (which sets up a DEBUG trap that fires immediately)
    RUBIES_DIR="${HOME}/.local/share/rv/rubies"
    if [[ -d $RUBIES_DIR ]]; then
      find $RUBIES_DIR -type d -empty -delete
      RUBIES=($RUBIES_DIR/*)
    fi

    # auto.sh sets a DEBUG trap for auto-switching ruby versions on cd.
    # Only useful in interactive shells; in scripts it breaks set -u (nounset)
    # because chruby_auto uses uninitialized variables.
    if [[ $- == *i* ]]; then
      . $chruby_dir/auto.sh
    fi
fi

alias lsa="ls -ahl"
alias b=bundle
alias l=/usr/local/bin/claude-login
alias s=/usr/local/bin/start.sh

link_dotfiles () {
  local dir=/settings/dotfiles

  for file in ${dir}/* ${dir}/.*; do
    local base
    base=$(basename "$file")
    [[ "$base" == "*" ]] && continue
    [[ "$base" == ".*" ]] && continue
    [[ "$base" == ".bashrc" ]] && continue
    [[ "$base" == ".bash_profile" ]] && continue
    ln -sf "$file" "$HOME"
  done
}

__git_ps1() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  [[ -z "$branch" ]] && return

  local status=""
  local git_status
  git_status=$(git status --porcelain 2>/dev/null)

  [[ -n "$git_status" ]] && status="*"
  git rev-parse --verify --quiet @{upstream} >/dev/null 2>&1 && {
    local ahead behind
    ahead=$(git rev-list --count @{upstream}..HEAD 2>/dev/null)
    behind=$(git rev-list --count HEAD..@{upstream} 2>/dev/null)
    [[ "$ahead" -gt 0 ]] && status="${status}↑${ahead}"
    [[ "$behind" -gt 0 ]] && status="${status}↓${behind}"
  }

  echo " (${branch}${status})"
}

PS1='\[\e[1;32m\]\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[1;33m\]$(__git_ps1)\[\e[0m\]\$ '

link_dotfiles

# source user's bashrc from dotfiles if present (after container setup)
[[ -f /settings/dotfiles/.bashrc ]] && source /settings/dotfiles/.bashrc
