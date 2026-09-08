#!/bin/bash

set -euo pipefail
# BASH_ENV startup files reset HOME and install a DEBUG trap that
# rewrites PATH, defeating fake homes and stubbed commands.
[[ -z "${BASH_ENV:-}" ]] || exec env -u BASH_ENV bash "$0" "$@"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/calls.log"
models="${tmpdir}/models.json"
settings="${tmpdir}/settings.json"
qwen_settings="${tmpdir}/qwen-settings.json"
extension="${tmpdir}/duration.ts"
guard_extension="${tmpdir}/guard.ts"
presets="${tmpdir}/models.ini"
mkdir -p "$fake_bin" "${tmpdir}/home"
: > "$extension"
: > "$guard_extension"
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
cp "$PI_CODING_AGENT_DIR/settings.json" "$LOCAL_CODE_TEST_SETTINGS"
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
LOCAL_CODE_TEST_SETTINGS="$settings" \
LOCAL_CODE_DURATION_EXTENSION="$extension" \
LOCAL_CODE_GUARD_EXTENSION="$guard_extension" \
LOCAL_CODE_PORT=18080 \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code.sh" --model gemma4 --print 'create example.rb'

grep -F 'curl args=<--fail --silent --show-error --header Authorization: Bearer local http://127.0.0.1:18080/health>' \
  "$log" >/dev/null
grep -F 'key=<local> print=<1>' "$log" >/dev/null
grep -F 'args=<--offline --provider llama-cpp --model gemma4' "$log" >/dev/null
grep -F -- '--session-dir /history/pi' "$log" >/dev/null
grep -F -- "--extension $extension --extension $guard_extension --print create example.rb>" "$log" >/dev/null
grep -F '"id": "qwen3coder"' "$models" >/dev/null
grep -F '"id": "gemma4"' "$models" >/dev/null
grep -F "\"apiKey\": \"\$LOCAL_CODE_API_KEY\"" "$models" >/dev/null
jq -e \
  '.providers["llama-cpp"].models[] |
  select(.id == "qwen3coder") |
  .name == "Qwen3-Coder-Next 80B-A3B Q5_K_M" and
  .contextWindow == 40960 and
  .reasoning == false and
  .samplingParams == {
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 40,
    "min_p": 0
  }' \
  "$models" >/dev/null
jq -e \
  '.providers["llama-cpp"].models[] | select(.id == "gemma4") | .contextWindow == 65536' \
  "$models" >/dev/null
jq -e '
  .providers["llama-cpp"].models[] |
  select(.id == "gemma4") |
  .samplingParams == {
    "dry_multiplier": 0.8,
    "dry_base": 1.75,
    "dry_allowed_length": 2,
    "dry_penalty_last_n": 256,
    "dry_sequence_breakers": ["<|dry-sequence-breaker|>"]
  }' "$models" >/dev/null
jq -e \
  '.compaction == {"enabled": true, "reserveTokens": 4096, "keepRecentTokens": 4096}' \
  "$settings" >/dev/null

HOME="${tmpdir}/home" \
LOCAL_CODE_TEST_LOG="$log" \
LOCAL_CODE_TEST_MODELS="$models" \
LOCAL_CODE_TEST_SETTINGS="$qwen_settings" \
LOCAL_CODE_DURATION_EXTENSION="$extension" \
LOCAL_CODE_GUARD_EXTENSION="$guard_extension" \
LOCAL_CODE_PORT=18080 \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code.sh" --print 'create example.rb'

grep -F 'args=<--offline --provider llama-cpp --model qwen3coder' "$log" >/dev/null
jq -e \
  '.compaction == {"enabled": true, "reserveTokens": 4096, "keepRecentTokens": 2048}' \
  "$qwen_settings" >/dev/null

if LOCAL_CODE_DURATION_EXTENSION="$extension" \
  LOCAL_CODE_GUARD_EXTENSION="$guard_extension" PATH="${fake_bin}:${PATH}" \
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

grep -F '[qwen3coder]' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
qwen_preset=$(sed -n '/^\[qwen3coder\]/,/^\[gemma4\]/p' "$SCRIPT_DIR/../lima/local-code-models.ini")
printf '%s\n' "$qwen_preset" | grep -Fx 'n-gpu-layers = 99' >/dev/null
printf '%s\n' "$qwen_preset" | grep -Fx 'kv-unified-per-slot = 40960' >/dev/null
printf '%s\n' "$qwen_preset" | grep -Fx 'flash-attn = on' >/dev/null
printf '%s\n' "$qwen_preset" | \
  grep -Fx 'model = /share/models/Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf' >/dev/null
printf '%s\n' "$qwen_preset" | \
  grep -Fx 'chat-template-file = /usr/local/share/ai/qwen-chat-template.jinja' >/dev/null
if printf '%s\n' "$qwen_preset" | grep -q '^reasoning-'; then
  echo 'at=fatal msg="Qwen3-Coder preset enables unsupported reasoning"' >&2
  exit 1
fi
grep -F '[gemma4]' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
grep -F 'n-gpu-layers = 20' "$SCRIPT_DIR/../lima/local-code-models.ini" >/dev/null
gemma_preset=$(sed -n '/^\[gemma4\]/,$p' "$SCRIPT_DIR/../lima/local-code-models.ini")
printf '%s\n' "$gemma_preset" | grep -Fx 'parallel = 1' >/dev/null
printf '%s\n' "$gemma_preset" | grep -Fx 'kv-unified-per-slot = 65536' >/dev/null
printf '%s\n' "$gemma_preset" | \
  grep -Fx 'chat-template-file = /usr/local/share/ai/gemma-chat-template.jinja' >/dev/null
if printf '%s\n' "$gemma_preset" | grep -q '^reasoning-format ='; then
  echo 'at=fatal msg="Gemma preset forces a non-native reasoning format"' >&2
  exit 1
fi
grep -Fx 'pi-local-guard.ts tools/pi-local-guard.ts project' \
  "$SCRIPT_DIR/../lima/assets/manifest.txt" >/dev/null
grep -Fx 'gemma-chat-template-version versions/gemma-chat-template project' \
  "$SCRIPT_DIR/../lima/assets/manifest.txt" >/dev/null
grep -F 'Qwen/Qwen3-Coder-Next/resolve/' \
  "$SCRIPT_DIR/../lima/provision.sh" >/dev/null
grep -Eq '^[0-9a-f]{40}$' "$SCRIPT_DIR/../versions/qwen-chat-template"
grep -F 'google/gemma-4-26B-A4B-it/resolve/' \
  "$SCRIPT_DIR/../lima/provision.sh" >/dev/null
grep -Eq '^[0-9a-f]{40}$' "$SCRIPT_DIR/../versions/gemma-chat-template"
node "$SCRIPT_DIR/test_pi_local_guard.mjs"

echo 'at=info msg="local code tests passed"'
