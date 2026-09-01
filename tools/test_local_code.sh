#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
server_pid=
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/calls.log"
model="${tmpdir}/Qwen-test.gguf"
template="${tmpdir}/template.jinja"
mkdir -p "$fake_bin"
: > "$model"
: > "$template"

cat > "${fake_bin}/llama-server" <<'EOF'
#!/bin/sh
printf 'llama <%s>\n' "$*" >> "$LOCAL_CODE_TEST_LOG"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
cat > "${fake_bin}/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${fake_bin}/pi" <<'EOF'
#!/bin/sh
printf 'pi config=<%s> args=<%s>\n' "$PI_CODING_AGENT_DIR" "$*" \
  >> "$LOCAL_CODE_TEST_LOG"
cp "$PI_CODING_AGENT_DIR/models.json" "$LOCAL_CODE_TEST_MODELS"
EOF
chmod +x "${fake_bin}/llama-server" "${fake_bin}/curl" "${fake_bin}/pi"

LOCAL_CODE_TEST_LOG="$log" \
LOCAL_CODE_TEST_MODELS="${tmpdir}/models.json" \
LOCAL_CODE_MODEL="$model" \
LOCAL_CODE_CHAT_TEMPLATE="$template" \
LOCAL_CODE_PORT=18080 \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/local-code.sh" --print 'create example.rb'

grep -F -- "--model $model" "$log" >/dev/null
grep -F -- '--gpu-layers 44' "$log" >/dev/null
grep -F -- '--parallel 1' "$log" >/dev/null
grep -F -- '--batch-size 32' "$log" >/dev/null
grep -F -- '--reasoning-format deepseek' "$log" >/dev/null
grep -F -- "--chat-template-file $template" "$log" >/dev/null
grep -F 'args=<--offline --provider llama-cpp --model local-coder --print create example.rb>' \
  "$log" >/dev/null
grep -F '"baseUrl": "http://127.0.0.1:18080/v1"' "${tmpdir}/models.json" >/dev/null
grep -F '"contextWindow": 8192' "${tmpdir}/models.json" >/dev/null

echo 'at=info msg="local code wrapper tests passed"'
