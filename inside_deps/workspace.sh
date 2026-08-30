#!/bin/bash

# Shared user-space toolchain provisioning for the OCI image and Lima VM.
set -euo pipefail

: "${HOME:?HOME is required}"
: "${RUBIES_DIR:?RUBIES_DIR is required}"

installers_dir=${1:?installer directory is required}
mise_tools_file=${2:?mise tool list is required}
brew_packages_file=${3:?Homebrew package list is required}
npm_packages_file=${4:?npm package list is required}
rv_ruby_versions_file=${5:?rv Ruby version list is required}
ruby_build_versions_file=${6:?ruby-build version list is required}

bash "$installers_dir/_brew.sh"
bash "$installers_dir/_nvm.sh"
sh "$installers_dir/_mise.sh"
sh "$installers_dir/_rv.sh"

cat > "$HOME/.bash_profile" <<'EOF'
export HOME=/workspace
export PATH=/workspace/.local/bin:$PATH:/workspace/.cargo/bin
eval "$(/workspace/.cargo/bin/rv shell init bash)"
eval "$(/workspace/.cargo/bin/rv shell completions bash)"
eval "$(/workspace/.local/bin/mise activate bash)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
source /workspace/.nvm/nvm.sh
EOF

export BASH_ENV="$HOME/.bash_profile"
bash -c 'brew --version && mise --version && rv --version'
while IFS= read -r tool; do
  bash -c 'mise use --global "$1"' _ "$tool"
done < "$mise_tools_file"
bash -c 'go version && python --version && rustc --version'
bash -c 'nvm install 22'

mapfile -t brew_packages < "$brew_packages_file"
bash -c 'brew install "$@"' _ "${brew_packages[@]}"
bash -c 'ast-grep --version'

mapfile -t npm_packages < "$npm_packages_file"
bash -c 'npm install --global "$@"' _ "${npm_packages[@]}"
bash -c 'node --version && npm --version'

while IFS= read -r version; do
  bash -c 'rv ruby install "$1"' _ "$version"
done < "$rv_ruby_versions_file"
bash -c 'rv run ruby --yjit --version && rv run bundle --version'

git clone --branch do-no-set-gem-home https://github.com/eregon/chruby.git "$HOME/chruby"
git clone https://github.com/rbenv/ruby-build.git "$HOME/ruby-build"
while IFS= read -r version; do
  bash -c 'ruby-build/bin/ruby-build "$1" "$RUBIES_DIR/$1"' _ "$version"
done < "$ruby_build_versions_file"
