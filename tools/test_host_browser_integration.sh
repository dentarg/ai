#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
chrome_pid=""
proxy_pid=""

cleanup() {
  if [[ -n $proxy_pid ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi
  if [[ -n $chrome_pid ]]; then
    kill "$chrome_pid" 2>/dev/null || true
    wait "$chrome_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

chromium \
  --headless \
  --no-sandbox \
  --user-data-dir="${tmpdir}/profile" \
  --remote-debugging-port=0 \
  about:blank >/dev/null 2>&1 &
chrome_pid=$!

for _attempt in {1..100}; do
  [[ -s ${tmpdir}/profile/DevToolsActivePort ]] && break
  sleep 0.05
done
upstream_port=$(sed -n '1p' "${tmpdir}/profile/DevToolsActivePort")

HOST_BROWSER_UPSTREAM_PORT="$upstream_port" \
HOST_BROWSER_TOKEN=integration-token \
HOST_BROWSER_ADVERTISED_HOST=127.0.0.1 \
HOST_BROWSER_CA_FILE="${tmpdir}/ca.pem" \
HOST_BROWSER_PORT_FILE="${tmpdir}/port" \
  ruby "$REPO_DIR/tools/host-browser-proxy.rb" >/dev/null 2>&1 &
proxy_pid=$!

for _attempt in {1..100}; do
  [[ -s ${tmpdir}/port ]] && break
  sleep 0.05
done
proxy_port=$(cat "${tmpdir}/port")

# JavaScript reads these values from process.env at runtime.
# shellcheck disable=SC2016
NODE_PATH=$(npm root -g) \
NODE_EXTRA_CA_CERTS="${tmpdir}/ca.pem" \
HOST_BROWSER_URL="https://127.0.0.1:${proxy_port}" \
HOST_BROWSER_TOKEN=integration-token \
  timeout 15 node -e '
    const puppeteer = require("puppeteer-core");
    (async () => {
      const authorization = `Bearer ${process.env.HOST_BROWSER_TOKEN}`;
      const browser = await puppeteer.connect({
        browserURL: process.env.HOST_BROWSER_URL,
        wsOptions: {headers: {Authorization: authorization}},
      });
      const page = await browser.newPage();
      await page.goto("data:text/html,<title>host-browser-ok</title>");
      if (await page.title() !== "host-browser-ok") process.exitCode = 1;
      await browser.disconnect();
    })().catch(error => {
      console.error(error);
      process.exit(1);
    });
  '

echo 'at=info msg="host browser end-to-end test passed"'
