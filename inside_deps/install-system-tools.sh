#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=inside_deps/install-utils.sh
source "$SCRIPT_DIR/install-utils.sh"

# RabbitMQ shares its default AMQP port with LavinMQ. Keep it opt-in.
if [[ -d /run/systemd/system ]]; then
  systemctl stop rabbitmq-server
fi
systemctl disable rabbitmq-server

erl -noshell -eval 'io:format("Erlang/OTP ~s~n", [erlang:system_info(otp_release)]), halt().'
rabbitmqctl version

# Ubuntu ships bat's binary as "batcat".
ln -sf /usr/bin/batcat /usr/local/bin/bat

# Official bundled Crystal release; 84codes packages still stop at 1.21.0.
# Checksums come from the GitHub release asset digests.
arch=$(dpkg --print-architecture)
case "$arch" in
  amd64)
    crystal_arch=x86_64
    crystal_sha=391dff4244d8d11c4422def9a2f930c9ba9fc9b7c85a20cbcc494472ab77bc0e
    ;;
  arm64)
    crystal_arch=aarch64
    crystal_sha=06e1408c6d759b6132a318ae65c6aecd070a9c3e6c8cc5d916cf25fd07cea8ef
    ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
download \
  --output /tmp/crystal.tar.gz \
  "https://github.com/crystal-lang/crystal/releases/download/1.21.1/crystal-1.21.1-1-linux-${crystal_arch}-bundled.tar.gz"
echo "${crystal_sha}  /tmp/crystal.tar.gz" | sha256sum -c -
tar -xzf /tmp/crystal.tar.gz --strip-components=2 -C /usr/local
rm /tmp/crystal.tar.gz

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
apt-get install -y --no-install-recommends gh glow lavinmq
rm -rf /var/lib/apt/lists/*
crystal --version
glow --version

# PostgreSQL
sed -i 's/scram-sha-256/trust/' /etc/postgresql/*/main/pg_hba.conf
service postgresql start
sudo -u postgres psql --command='CREATE ROLE root WITH LOGIN SUPERUSER;'

# Loki logcli. Checksums come from the SHA256SUMS file for the pinned release.
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

# Tailcat — netcat over Tailscale's data plane. Checksums come from the
# checksums.txt file for the pinned release.
tailcat_version=0.4.0
case "$arch" in
  amd64) tailcat_sha=38ff4b45fe56b32c75738c10dfed4f0b68d33bee49a19695f4bb9f9ec5d6e3c0 ;;
  arm64) tailcat_sha=8f1835a3522ecfc855c9f4ece51c2266781fd03ce76da48036b08c4b86193899 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
download \
  --output /tmp/tailcat.deb \
  "https://github.com/tailscale/tailcat/releases/download/v${tailcat_version}/tailcat_${tailcat_version}_linux_${arch}.deb"
echo "${tailcat_sha}  /tmp/tailcat.deb" | sha256sum -c -
dpkg --install /tmp/tailcat.deb
dpkg-query --showformat='${Version}\n' --show tailcat | grep -Fx "$tailcat_version"
rm /tmp/tailcat.deb

# These services are started explicitly when needed; do not slow sandbox boot.
systemctl disable postgresql lavinmq redis-server
