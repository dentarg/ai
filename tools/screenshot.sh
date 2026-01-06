#!/bin/sh
set -e

url="${1:?Usage: screenshot.sh <url> [output.png]}"
output="${2:-screenshot.png}"

chromium \
  --headless \
  --disable-gpu \
  --no-sandbox \
  --screenshot="$output" \
  --window-size=1280,800 \
  "$url" 2>/dev/null

echo "at=info msg=\"screenshot saved\" path=$output"
