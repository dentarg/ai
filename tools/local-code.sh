#!/bin/sh

set -eu

usage() {
  cat <<EOF
Usage: local-code [--model qwen38|gemma4] [pi options] [prompt]

Connect Pi to the shared local llama.cpp server. The --model option must come
before Pi's options. qwen38 is the default.
EOF
}

model=qwen38
case "${1:-}" in
  --model)
    shift
    if [ "$#" -eq 0 ]; then
      echo 'at=fatal msg="--model requires an alias"' >&2
      exit 1
    fi
    model=$1
    shift
    ;;
  --model=*)
    model=${1#--model=}
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

case "$model" in
  qwen38|gemma4) ;;
  *)
    echo "at=fatal msg=\"unknown local model\" model=\"$model\"" >&2
    exit 1
    ;;
esac

port=${LOCAL_CODE_PORT:-8080}
base_url=${LOCAL_CODE_BASE_URL:-http://127.0.0.1:${port}/v1}
api_key=${LOCAL_CODE_API_KEY:-local}
extension=${LOCAL_CODE_DURATION_EXTENSION:-/usr/local/share/ai/pi-duration.ts}
session_dir=${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.pi/agent/sessions}

if [ ! -f "$extension" ]; then
  echo "at=fatal msg=\"Pi duration extension not found\" path=\"$extension\"" >&2
  exit 1
fi
if [ -z "$api_key" ]; then
  echo 'at=fatal msg="LOCAL_CODE_API_KEY cannot be empty"' >&2
  exit 1
fi
case "$base_url" in
  *'"'*)
    echo 'at=fatal msg="LOCAL_CODE_BASE_URL contains unsupported characters"' >&2
    exit 1
    ;;
esac

server_url=${base_url%/}
server_url=${server_url%/v1}
if ! curl --fail --silent --show-error \
  --header "Authorization: Bearer ${api_key}" \
  "${server_url}/health" >/dev/null; then
  echo "at=fatal msg=\"local coding server is unavailable\" url=\"$server_url\"" >&2
  exit 1
fi

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/local-code.XXXXXX")
cleanup() {
  rm -rf "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cat >"${runtime_dir}/models.json" <<EOF
{
  "providers": {
    "llama-cpp": {
      "baseUrl": "${base_url}",
      "api": "openai-completions",
      "apiKey": "\$LOCAL_CODE_API_KEY",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "qwen38",
          "name": "Qwen3.8 27B IQ4_XS",
          "reasoning": true,
          "contextWindow": 8192,
          "maxTokens": 4096
        },
        {
          "id": "gemma4",
          "name": "Gemma 4 26B A4B Q4_0",
          "reasoning": true,
          "contextWindow": 8192,
          "maxTokens": 4096
        }
      ]
    }
  }
}
EOF

LOCAL_CODE_API_KEY=$api_key
LOCAL_CODE_PRINT_MODE=0
for argument in "$@"; do
  case "$argument" in
    -p|--print) LOCAL_CODE_PRINT_MODE=1 ;;
  esac
done
PI_CODING_AGENT_DIR="$runtime_dir"
export LOCAL_CODE_API_KEY LOCAL_CODE_PRINT_MODE PI_CODING_AGENT_DIR

pi \
  --offline \
  --provider llama-cpp \
  --model "$model" \
  --session-dir "$session_dir" \
  --extension "$extension" \
  "$@"
