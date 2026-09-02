#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/calls.log"
models="${tmpdir}/models.json"
extension="${tmpdir}/duration.ts"
presets="${tmpdir}/models.ini"
mkdir -p "$fake_bin" "${tmpdir}/home"
: > "$extension"
: > "$presets"

cat > "${fake_bin}/curl" <<'EOF'
#!/bin/sh
printf 'curl args=<%s>\n' "$*" >> "$LOCAL_CODE_TEST_LOG"
EOF
cat > "${fake_bin}/pi" <<'EOF'
#!/bin/sh
printf 'pi config=<%s> key=<%s> print=<%s> args=<%s>\n' \
  "$PI_CODING_AGENT_DIR" "$LOCAL_CODE_API_KEY" \
  "$LOCAL_CODE_PRINT_MODE" "$*" >> "$LOCAL_CODE_TEST_LOG"
cp "$PI_CODING_AGENT_DIR/models.json" "$LOCAL_CODE_TEST_MODELS"
EOF
cat > "${fake_bin}/llama-server" <<'EOF'
#!/bin/sh
printf 'server f16=<%s> args=<%s>\n' "$GGML_VK_DISABLE_F16" "$*" \
  >> "$LOCAL_CODE_TEST_LOG"
EOF
chmod +x "${fake_bin}/curl" "${fake_bin}/pi" "${fake_bin}/llama-server"

HOME="${tmpdir}/home" \
LOCAL_CODE_TEST_LOG="$log" \
LOCAL_CODE_TEST_MODELS="$models" \
LOCAL_CODE_DURATION_EXTENSION="$extension" \
LOCAL_CODE_PORT=18080 \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code.sh" --model gemma4 --print 'create example.rb'

grep -F 'curl args=<--fail --silent --show-error --header Authorization: Bearer local http://127.0.0.1:18080/health>' \
  "$log" >/dev/null
grep -F 'key=<local> print=<1>' "$log" >/dev/null
grep -F 'args=<--offline --provider llama-cpp --model gemma4' "$log" >/dev/null
grep -F -- "--session-dir ${tmpdir}/home/.pi/agent/sessions" "$log" >/dev/null
grep -F -- "--extension $extension --print create example.rb>" "$log" >/dev/null
grep -F '"id": "qwen38"' "$models" >/dev/null
grep -F '"id": "gemma4"' "$models" >/dev/null
grep -F "\"apiKey\": \"\$LOCAL_CODE_API_KEY\"" "$models" >/dev/null
jq -e \
  '.providers["llama-cpp"].models[] | select(.id == "gemma4") | .contextWindow == 16384' \
  "$models" >/dev/null

if LOCAL_CODE_DURATION_EXTENSION="$extension" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code.sh" --model unknown >/dev/null 2>&1; then
  echo 'at=fatal msg="local-code accepted an unknown model"' >&2
  exit 1
fi

LOCAL_CODE_TEST_LOG="$log" \
LOCAL_CODE_PRESETS="$presets" \
LOCAL_CODE_HOST=0.0.0.0 \
LOCAL_CODE_PORT=18081 \
LOCAL_CODE_API_KEY=test-key \
LOCAL_CODE_GPU_LAYERS=18 \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code-server.sh"

grep -F 'server f16=<1>' "$log" >/dev/null
grep -F -- "--models-preset $presets --models-max 1" "$log" >/dev/null
grep -F -- '--host 0.0.0.0 --port 18081 --api-key test-key' "$log" >/dev/null
grep -F -- '--gpu-layers 18' "$log" >/dev/null

grep -F '[qwen38]' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
grep -F 'n-gpu-layers = 44' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
grep -F '[gemma4]' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
grep -F 'n-gpu-layers = 20' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
gemma_preset=$(sed -n '/^\[gemma4\]/,$p' "$SCRIPT_DIR/../lima/local-code-models.ini")
printf '%s\n' "$gemma_preset" | grep -Fx 'parallel = 1' >/dev/null
printf '%s\n' "$gemma_preset" | grep -Fx 'kv-unified-per-slot = 16384' >/dev/null

echo 'at=info msg="local code tests passed"'
