#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
image=ai-workspace-test:latest

# Exercise the production BuildKit stage, including the real Homebrew installer.
docker build --target workspace --tag "$image" "$REPO_DIR"
docker run --rm --entrypoint bash "$image" -c '
  set -euo pipefail
  [[ $(id -u) == 0 ]]
  [[ $(stat -c %U /workspace) == ai-build ]]
  [[ $(stat -c %U /home/linuxbrew/.linuxbrew) == ai-build ]]
  node --version
  rv run ruby --version
  sudo -u ai-build env BASH_ENV=/workspace/.bash_profile bash -c '\''
    set -euo pipefail
    [[ $(id -u) != 0 ]]
    test -w /workspace
    test -w /home/linuxbrew/.linuxbrew
    brew list --versions ast-grep terraform toxiproxy
    node --version
    rv run ruby --version
  '\''
'

echo 'at=info msg="image workspace tests passed"'
