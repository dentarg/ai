#!/bin/sh

set -eu

host=${LOCAL_CODE_HOST:-127.0.0.1}
port=${LOCAL_CODE_PORT:-8080}
api_key=${LOCAL_CODE_API_KEY:-local}
presets=${LOCAL_CODE_PRESETS:-/usr/local/share/ai/local-code-models.ini}
gpu_layers=${LOCAL_CODE_GPU_LAYERS:-}

if [ ! -f "$presets" ]; then
  echo "at=fatal msg=\"model presets not found\" path=\"$presets\"" >&2
  exit 1
fi
if [ -z "$api_key" ]; then
  echo 'at=fatal msg="LOCAL_CODE_API_KEY cannot be empty"' >&2
  exit 1
fi

set -- \
  llama-server \
  --models-preset "$presets" \
  --models-max 1 \
  --host "$host" \
  --port "$port" \
  --api-key "$api_key"
if [ -n "$gpu_layers" ]; then
  set -- "$@" --gpu-layers "$gpu_layers"
fi

GGML_VK_DISABLE_F16=${GGML_VK_DISABLE_F16:-1}
export GGML_VK_DISABLE_F16
exec "$@"
