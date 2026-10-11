#!/bin/bash

set -euo pipefail
# Tests fake HOME; a BASH_ENV startup file could reset it to the real one.
unset BASH_ENV

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Load only the linker so the test does not need a provisioned workspace.
source <(sed -n '/^link_dotfiles () {$/,/^}$/p' "$REPO_DIR/dot.bashrc")
export HOME="$tmpdir/home"
dotfiles="$tmpdir/dotfiles"
mkdir -p "$HOME/.config" "$dotfiles/.config" "$dotfiles/theme" "$tmpdir/old-theme"
printf 'keep\n' > "$HOME/.config/settings"
touch "$dotfiles/.bashrc" "$dotfiles/.bash_profile" "$dotfiles/.gitconfig"
touch "$dotfiles/file with spaces"
ln -s "$tmpdir/old-theme" "$HOME/theme"

link_dotfiles "$dotfiles"
link_dotfiles "$dotfiles"

[[ $(cat "$HOME/.config/settings") == keep ]]
[[ ! -L "$HOME/.config" ]]
[[ $(readlink "$HOME/theme") == "$dotfiles/theme" ]]
[[ ! -e "$tmpdir/old-theme/theme" ]]
[[ $(readlink "$HOME/.gitconfig") == "$dotfiles/.gitconfig" ]]
[[ $(readlink "$HOME/file with spaces") == "$dotfiles/file with spaces" ]]
[[ ! -e "$HOME/.bashrc" && ! -e "$HOME/.bash_profile" ]]
[[ ! -L "$HOME/dotfiles" && ! -L "$HOME/.." ]]

mkdir "$tmpdir/empty"
link_dotfiles "$tmpdir/empty"
link_dotfiles "$tmpdir/missing"

echo 'at=info msg="dotfile linking tests passed"'
