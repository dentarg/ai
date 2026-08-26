#!/bin/sh

set -eu

usage() {
  echo "Usage: op-read <secret-alias>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

alias_name=$1
case "$alias_name" in
  ''|*[!a-z0-9._-]*) usage ;;
esac

: "${OP_BRIDGE_URL:?op-read is unavailable; launch bin/ai with --1password}"
: "${OP_BRIDGE_TOKEN:?OP_BRIDGE_TOKEN is not set}"
: "${OP_BRIDGE_CA:?OP_BRIDGE_CA is not set}"

curl \
  --silent \
  --show-error \
  --fail \
  --request POST \
  --noproxy '*' \
  --cacert "$OP_BRIDGE_CA" \
  --header "Authorization: Bearer ${OP_BRIDGE_TOKEN}" \
  "${OP_BRIDGE_URL}/v1/secrets/${alias_name}"
