#!/bin/bash

set -e

history_dir () {
  local tool=$1
  local year=$(date +%Y)
  local month=$(date +%m_%b)
  local day_time=$(date +%d_%a_%H-%M)
  echo "/history/${year}/${month}/${day_time}_${tool}"
}

profile=${1:-}

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
  exit 1
fi

settings_home=$(history_dir gemini)

rm -f $HOME/.gemini # should be a symlink
mkdir -p $settings_home
ln -s $settings_home $HOME/.gemini

cp $settings_gemini/google_accounts.json $HOME/.gemini
cp $settings_gemini/installation_id      $HOME/.gemini
cp $settings_gemini/oauth_creds.json     $HOME/.gemini
cp $settings_gemini/settings.json        $HOME/.gemini
cp $settings_gemini/state.json           $HOME/.gemini
cp /settings/AGENTS.md                   $HOME/.gemini/GEMINI.md

exec gemini --yolo
