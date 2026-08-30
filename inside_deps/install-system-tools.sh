#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=inside_deps/install-utils.sh
source "$SCRIPT_DIR/install-utils.sh"

# Ubuntu ships bat's binary as "batcat".
ln -sf /usr/bin/batcat /usr/local/bin/bat

# Crystal (there are no Ubuntu 26.04 packages yet).
download https://packagecloud.io/84codes/crystal/gpgkey | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/84codes_crystal.gpg
echo 'deb https://packagecloud.io/84codes/crystal/ubuntu noble main' \
  > /etc/apt/sources.list.d/84codes_crystal.list

# LavinMQ (there are no Ubuntu 26.04 packages yet).
download https://packagecloud.io/cloudamqp/lavinmq/gpgkey | \
  gpg --dearmor > /usr/share/keyrings/lavinmq.gpg
echo 'deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu noble main' \
  > /etc/apt/sources.list.d/lavinmq.list

# GitHub CLI. Keep GitHub's repository because gh develops more rapidly than
# the Ubuntu-packaged version.
download \
  --output /usr/share/keyrings/githubcli-archive-keyring.gpg \
  https://cli.github.com/packages/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# glow
download https://repo.charm.sh/apt/gpg.key | \
  gpg --dearmor --output /usr/share/keyrings/charm.gpg
echo 'deb [signed-by=/usr/share/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *' \
  > /etc/apt/sources.list.d/charm.list

apt-get update
apt-get install -y --no-install-recommends crystal gh glow lavinmq
rm -rf /var/lib/apt/lists/*
crystal --version
glow --version

# PostgreSQL
sed -i 's/scram-sha-256/trust/' /etc/postgresql/*/main/pg_hba.conf
service postgresql start
sudo -u postgres psql --command='CREATE ROLE root WITH LOGIN SUPERUSER;'

# Loki logcli. Checksums come from the SHA256SUMS file for the pinned release.
arch=$(dpkg --print-architecture)
case "$arch" in
  amd64) logcli_sha=7850d566d2af10d7adf255ed9452de632ab20c0f269dc61fac7f70bed4d99e48 ;;
  arm64) logcli_sha=2fec7cbf4c0929f2fbd1e339753b14bc6432aadb41abf4b4155b00d3f6509e4e ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
download \
  --output /tmp/logcli.zip \
  "https://github.com/grafana/loki/releases/download/v3.7.2/logcli-linux-${arch}.zip"
echo "${logcli_sha}  /tmp/logcli.zip" | sha256sum -c -
unzip -p /tmp/logcli.zip "logcli-linux-${arch}" > /usr/local/bin/logcli
chmod +x /usr/local/bin/logcli
rm /tmp/logcli.zip
logcli --version

pip install mitmproxy

# These services are started explicitly when needed; do not slow sandbox boot.
systemctl disable postgresql lavinmq redis-server
