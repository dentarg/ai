#!/bin/bash

# Download and run this script from Claude Code's cloud environment Setup script.
# Adapted from inside_deps for the hosted Ubuntu sandbox.
set -euo pipefail
trap 'printf "at=error event=setup_failed line=%s\n" "$LINENO" >&2' ERR

# Installer source pinned to a reviewed version of this repository.
ai_revision=352a4a44a44f549666e485ab198011d569fd4ef9
ruby_versions=(3.4.11 4.0.7)

if [[ $(uname -s) != Linux || $(id -u) != 0 ]]; then
  echo 'at=error msg="This setup requires the root Linux cloud sandbox"' >&2
  exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release
if [[ $ID != ubuntu ]]; then
  echo 'at=error msg="This setup requires Ubuntu"' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
setup_tmp=$(mktemp -d)
trap 'rm -rf "$setup_tmp"' EXIT

download() {
  curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 15 --max-time 120 "$@"
}

# debconf's noninteractive mode does not handle dpkg conffile prompts.
# Keep the hosted environment's existing configuration on package conflicts.
printf 'at=info event=install_packages\n'
apt-get update -qq
apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends \
  bat build-essential ca-certificates cmake curl file git git-lfs gnupg \
  htop jq less libcurl4-openssl-dev libffi-dev libgmp-dev liblz4-dev \
  libpq-dev libreadline-dev libssl-dev libyaml-dev libzstd-dev lsof \
  netcat-openbsd pkg-config postgresql-client ragel ripgrep rsync \
  shellcheck silversearcher-ag socat sqlite3 strace tmux tree unzip \
  vim wget zip zlib1g-dev zsh

# Use the same Crystal and LavinMQ repositories as the image build.
# Both publish Ubuntu noble packages; use scoped signing keys.
install -d -m 755 /usr/share/keyrings
for entry in 84codes/crystal cloudamqp/lavinmq; do
  name=${entry##*/}
  download "https://packagecloud.io/$entry/gpgkey" \
    --output "$setup_tmp/$name.asc"
  gpg --batch --yes --dearmor --output "/usr/share/keyrings/ai-$name.gpg" \
    "$setup_tmp/$name.asc"
  chmod 644 "/usr/share/keyrings/ai-$name.gpg"
  printf 'deb [signed-by=/usr/share/keyrings/ai-%s.gpg] https://packagecloud.io/%s/ubuntu noble main\n' \
    "$name" "$entry" > "/etc/apt/sources.list.d/ai-$name.list"
done
apt-get update -qq
apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends crystal lavinmq

printf 'at=info event=install_ruby\n'
download "https://raw.githubusercontent.com/dentarg/ai/$ai_revision/inside_deps/_rv.sh" \
  --output "$setup_tmp/rv-installer.sh"
RV_INSTALL_DIR=/usr/local/bin RV_NO_MODIFY_PATH=1 \
  sh "$setup_tmp/rv-installer.sh"
for version in "${ruby_versions[@]}"; do
  /usr/local/bin/rv ruby install "$version"
done

# Explicit rv commands respect each project's .ruby-version. Do not replace
# the hosting environment's default Ruby or shell initialization files.
/usr/local/bin/rv run ruby --version
/usr/local/bin/rv run bundle --version

printf 'at=info event=install_node_tools\n'
# Claude's hosted image already provides Node 22 and npm.
# A fixed prefix makes the CLIs available without shell activation.
npm install --global --prefix /usr/local @ast-grep/cli puppeteer-core

# Only add bat's conventional name if the environment doesn't provide it.
if ! command -v bat >/dev/null 2>&1; then
  ln -s /usr/bin/batcat /usr/local/bin/bat
fi

crystal --version
/usr/local/bin/ast-grep --version
shellcheck --version
printf 'at=info event=setup_complete\n'
