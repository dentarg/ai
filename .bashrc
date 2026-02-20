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

# the default is too low
ulimit -n 10480

# chruby
chruby_dir="${HOME}/chruby/share/chruby"
if [ -f $chruby_dir/chruby.sh ]; then
    . $chruby_dir/chruby.sh

    # Set RUBIES after chruby.sh (which initializes it as empty) but before
    # auto.sh (which sets up a DEBUG trap that fires immediately)
    RUBIES_DIR="${HOME}/.data/rv/rubies"
    if [[ -d $RUBIES_DIR ]]; then
      find $RUBIES_DIR -type d -empty -delete
      RUBIES=($RUBIES_DIR/*)
    fi

    . $chruby_dir/auto.sh
fi

alias b=bundle
alias s=/usr/local/bin/start.sh

link_dotfiles () {
  local dir=/settings/dotfiles

  for file in ${dir}/* ${dir}/.*; do
    [[ "$(basename $file)" == "*" ]] && continue
    [[ "$(basename $file)" == ".*" ]] && continue
    ln -sf $file $HOME
  done
}

history_dir () {
  local tool=$1
  local year=$(date +%Y)
  local month=$(date +%m_%b)
  local day_time=$(date +%d_%a_%H-%M)
  echo "/history/${year}/${month}/${day_time}_${tool}"
}

oc () {
  if [[ ! -d /settings/codex ]]; then
    echo "/settings/codex not found!"
    echo ""
    echo "  First time? You want to create /settings/codex/auth.json with OPENAI_API_KEY"
    echo ""
    return 1
  fi

  local settings_home=$(history_dir codex)

  rm -f $HOME/.codex # should be a symlink
  mkdir -p $settings_home
  ln -s $settings_home $HOME/.codex

  cp /settings/codex/auth.json $HOME/.codex
  cp /settings/AGENTS.md       $HOME/.codex

  codex \
    --dangerously-bypass-approvals-and-sandbox \
    --search
}

g () {
  local profile=${1:-}

  if [[ -n "$profile" ]]; then
    settings_gemini=/settings/gemini_${profile}
  else
    settings_gemini=/settings/gemini
  fi

  if [[ ! -d $settings_gemini ]]; then
    echo "$settings_gemini not found!"
    echo ""
    echo "  First time? Start gemini and authenticate."
    echo "  Inspect ~/.gemini and copy needed files (see /etc/profile.bashrc) to /settings/gemini"
    echo ""
    return 1
  fi

  local settings_home=$(history_dir gemini)

  rm -f $HOME/.gemini # should be a symlink
  mkdir -p $settings_home
  ln -s $settings_home $HOME/.gemini

  cp $settings_gemini/google_accounts.json $HOME/.gemini
  cp $settings_gemini/installation_id      $HOME/.gemini
  cp $settings_gemini/oauth_creds.json     $HOME/.gemini
  cp $settings_gemini/settings.json        $HOME/.gemini
  cp $settings_gemini/state.json           $HOME/.gemini
  cp /settings/AGENTS.md                   $HOME/.gemini/GEMINI.md

  gemini --yolo
}

cool_claude () {
  local profile=${1:-}
  local settings_claude_json
  local settings_claude_home=$(history_dir claude)

  rm -f $HOME/.claude/.credentials.json
  rm -f $HOME/.claude # should be a symlink
  rm -f $HOME/.claude.json
  rm -f $HOME/.claude.json.backup

  if [[ -n "$profile" ]]; then
    settings_claude_json=/settings/.claude.${profile}.json

    # oauth accounts uses separate file with access token and refresh token
    if [[ -f $settings_claude_json ]] && grep -q "oauthAccount" "$settings_claude_json"; then
      mkdir -p $settings_claude_home
      ln -s $settings_claude_home $HOME/.claude

      local settings_credentials=/settings/.credentials.${profile}.json
      test -f $settings_credentials && cp -f $settings_credentials $HOME/.claude/.credentials.json
    fi
  else
    settings_claude_json=/settings/.claude.json
  fi

  if [[ ! -f $settings_claude_json ]]; then
    echo "$settings_claude_json not found!"
    return 1
  fi

  [[ ! -L $HOME/.claude ]] && mkdir -p $settings_claude_home && ln -s $settings_claude_home $HOME/.claude

  cp -f $settings_claude_json $settings_claude_home/.claude.json # keep a copy
  ln -s $settings_claude_home/.claude.json $HOME/.claude.json    # link it
  [[ -f /settings/AGENTS.md ]] && cp -f /settings/AGENTS.md $HOME/.claude/CLAUDE.md

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
