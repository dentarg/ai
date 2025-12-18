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

alias b=bundle
alias s=/start.sh

link_dotfiles () {
  local dir=/settings/dotfiles

  for file in ${dir}/* ${dir}/.*; do
    [[ "$(basename $file)" == "*" ]] && continue
    ln -sf $file $HOME
  done
}

cool_claude () {
  local claude_home="/history/claude_$(date +%Y%m%d%H%M)"

  mkdir -p $claude_home
  ln -s $claude_home $HOME/.claude
  cp -f /settings/CLAUDE.md $HOME/.claude || true

  claude \
    --dangerously-skip-permissions \
    --model opus
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
