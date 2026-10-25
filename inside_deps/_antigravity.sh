#!/bin/bash

set -euo pipefail

manifest=${1:?Antigravity release manifest is required}
destination=${2:-"$HOME/.local/bin/antigravity-cli"}

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo 'at=fatal msg="unsupported Antigravity operating system"' >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'at=fatal msg="unsupported Antigravity architecture"' >&2; exit 1 ;;
esac

release=$(jq -ce --arg platform "${os}_${arch}" '
  .[$platform] | select(
    (.version | type == "string") and
    (.url | startswith("https://storage.googleapis.com/antigravity-public/antigravity-cli/")) and
    (.sha512 | test("^[a-f0-9]{128}$"))
  )
' "$manifest")
url=$(jq -r .url <<< "$release")
checksum=$(jq -r .sha512 <<< "$release")

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
curl -fsSL --retry 3 "$url" -o "$staging/download"
printf '%s  %s\n' "$checksum" "$staging/download" | shasum -a 512 -c -
case "$url" in
  *.tar.gz) tar -xzf "$staging/download" -C "$staging" antigravity ;;
  *) mv "$staging/download" "$staging/antigravity" ;;
esac
mkdir -p "$(dirname "$destination")"
install -m 755 "$staging/antigravity" "$destination"
"$destination" --version
