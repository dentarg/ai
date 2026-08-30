#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=inside_deps/install-utils.sh
source "$SCRIPT_DIR/install-utils.sh"

packages_file=${1:?chromium package list is required}

# Ubuntu's Chromium package is a snap wrapper, which is unsuitable for both
# the container and VM sandboxes. Install Debian's regular build instead.
apt-get update
xargs apt-get install -y --no-install-recommends < "$packages_file"
download \
  --output /tmp/debian.asc \
  https://ftp-master.debian.org/keys/archive-key-12.asc
gpg --batch --yes --dearmor \
  --output /usr/share/keyrings/debian-archive.gpg \
  /tmp/debian.asc
echo 'deb [signed-by=/usr/share/keyrings/debian-archive.gpg] http://deb.debian.org/debian sid main' \
  > /etc/apt/sources.list.d/debian-sid.list
apt-get update
apt-get install -y --no-install-recommends chromium
rm -rf /var/lib/apt/lists/* /tmp/debian.asc
