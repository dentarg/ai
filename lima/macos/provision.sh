#!/bin/bash
set -euo pipefail
assets=/tmp/ai-macos-build
export HOMEBREW_NO_ASK=1 HOMEBREW_NO_ANALYTICS=1 NONINTERACTIVE=1
if [[ ! -x /opt/homebrew/bin/brew ]]; then
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/ai-homebrew.sh
  /bin/bash /tmp/ai-homebrew.sh
  rm /tmp/ai-homebrew.sh
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install bash coreutils findutils gnu-sed gnu-tar grep jq git git-lfs \
  ripgrep ast-grep bat ncurses node@22 ruby python go rust mise fnox \
  postgresql@17 redis lavinmq
cat > "$HOME/.bash_profile" <<'PROFILE'
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH
export PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/opt/ruby/bin:$PATH
export PATH=/opt/homebrew/opt/postgresql@17/bin:$PATH
for tool in coreutils findutils gnu-sed gnu-tar grep; do
  export PATH="/opt/homebrew/opt/$tool/libexec/gnubin:$PATH"
done
PROFILE
source "$HOME/.bash_profile"
while IFS= read -r package; do
  [[ -n "$package" ]] && npm install -g "$package"
done < "$assets/inside_deps/npm-packages.txt"
npm install -g "@openai/codex@$(cat "$assets/versions/codex")"
bash "$assets/lima/assets/claude.sh" "$(cat "$assets/versions/claude-code")"
rm -rf "$HOME/.claude"
sudo mkdir -p /usr/local/bin /opt/codex-plugins
sudo chown "$(id -un)":staff /opt/codex-plugins
bash "$assets/inside_deps/_codex_plugins.sh" "$assets/versions/codex-plugins" /opt/codex-plugins
sudo chown -R root:wheel /opt/codex-plugins
for mapping in claude.sh:c codex.sh:cx gemini.sh:g claude-hook.sh:claude-hook \
  claude-permission-hook.sh:claude-permission-hook claude-login.sh:claude-login \
  op-read.sh:op-read exit.sh:x; do
  sudo install -m 755 "$assets/tools/${mapping%:*}" "/usr/local/bin/${mapping#*:}"
done
for tool in codex-login refresh-tokens; do
  sudo install -m 755 "$assets/bin/$tool" "/usr/local/bin/$tool"
done
sudo install -m 755 "$assets/lima/macos/start.sh" /usr/local/bin/start.sh
install -m 644 "$assets/dot.bashrc" "$HOME/.bashrc"
sudo install -m 644 "$assets/lima/assets/gitconfig" /etc/gitconfig
sudo install -m 644 "$assets/gitignore-global" /etc/gitignore
git lfs install
# Native macOS gems stay separate from the Linux bundle cache on the host.
mkdir -p "$HOME/.local/bin"
touch "$HOME/.ai-macos-provisioned"
echo 'at=info msg="macOS provisioning complete"'
