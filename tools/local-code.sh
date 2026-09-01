#!/bin/sh

set -eu

model=${LOCAL_CODE_MODEL:-/share/models/Qwen3.8-27B-UD-IQ4_XS.gguf}
port=${LOCAL_CODE_PORT:-8080}
context=${LOCAL_CODE_CONTEXT:-8192}
gpu_layers=${LOCAL_CODE_GPU_LAYERS:-44}
template=${LOCAL_CODE_CHAT_TEMPLATE:-}

if [ ! -f "$model" ]; then
  echo "at=fatal msg=\"local coding model not found\" model=\"$model\"" >&2
  exit 1
fi

if [ -z "$template" ]; then
  case "$(basename "$model")" in
    Qwen*) template=/usr/local/share/ai/qwen-chat-template.jinja ;;
  esac
fi
if [ -n "$template" ] && [ ! -f "$template" ]; then
  echo "at=fatal msg=\"chat template not found\" template=\"$template\"" >&2
  exit 1
fi

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/local-code.XXXXXX")
server_log="${runtime_dir}/server.log"
server_pid=
# Invoked by the signal traps below.
# shellcheck disable=SC2329
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

GGML_VK_DISABLE_F16=${GGML_VK_DISABLE_F16:-1}
export GGML_VK_DISABLE_F16
if [ -n "$template" ]; then
  llama-server \
    --model "$model" \
    --alias local-coder \
    --host 127.0.0.1 \
    --port "$port" \
    --gpu-layers "$gpu_layers" \
    --no-kv-offload \
    --ctx-size "$context" \
    --parallel 1 \
    --batch-size 32 \
    --ubatch-size 16 \
    --jinja \
    --reasoning-format deepseek \
    --reasoning-preserve \
    --no-mmproj \
    --chat-template-file "$template" \
    >"$server_log" 2>&1 &
else
  llama-server \
    --model "$model" \
    --alias local-coder \
    --host 127.0.0.1 \
    --port "$port" \
    --gpu-layers "$gpu_layers" \
    --no-kv-offload \
    --ctx-size "$context" \
    --parallel 1 \
    --batch-size 32 \
    --ubatch-size 16 \
    --jinja \
    --reasoning-format deepseek \
    --reasoning-preserve \
    --no-mmproj \
    >"$server_log" 2>&1 &
fi
server_pid=$!

attempt=0
until curl --fail --silent "http://127.0.0.1:${port}/health" >/dev/null; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    echo 'at=fatal msg="llama server exited during startup"' >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 480 ]; then
    cat "$server_log" >&2
    echo 'at=fatal msg="timed out waiting for llama server"' >&2
    exit 1
  fi
  sleep 0.25
done

cat >"${runtime_dir}/models.json" <<EOF
{
  "providers": {
    "llama-cpp": {
      "baseUrl": "http://127.0.0.1:${port}/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "local-coder",
          "name": "Local coder",
          "reasoning": true,
          "contextWindow": ${context},
          "maxTokens": 4096
        }
      ]
    }
  }
}
EOF

PI_CODING_AGENT_DIR="$runtime_dir"
export PI_CODING_AGENT_DIR

if pi --offline --provider llama-cpp --model local-coder "$@"; then
  exit 0
else
  status=$?
  cat "$server_log" >&2
  exit "$status"
fi
