#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fake_bin=${tmpdir}/bin
log=${tmpdir}/calls.log
mkdir -p "$fake_bin" "${tmpdir}/home"
: > "$log"

cat > "${fake_bin}/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) exit 2 ;;
esac
EOF
cat > "${fake_bin}/model-download" <<'EOF'
#!/bin/sh
printf 'model-download args=<%s>\n' "$*" >> "$LOCAL_CODE_HOST_TEST_LOG"
if [ "$1" = --path ]; then
  printf '%s/model.gguf\n' "$3"
  exit
fi
mkdir -p "$2"
: > "$2/model.gguf"
EOF
cat > "${fake_bin}/curl" <<'EOF'
#!/bin/sh
printf 'curl args=<%s>\n' "$*" >> "$LOCAL_CODE_HOST_TEST_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    shift
    printf 'template\n' > "$1"
    exit
  fi
  shift
done
exit 2
EOF
cat > "${fake_bin}/openssl" <<'EOF'
#!/bin/sh
printf 'test-api-key\n'
EOF
cat > "${fake_bin}/llama-server" <<'EOF'
#!/bin/sh
printf 'llama-server args=<%s>\n' "$*" >> "$LOCAL_CODE_HOST_TEST_LOG"
EOF
cat > "${fake_bin}/git" <<'EOF'
#!/bin/sh
printf 'git args=<%s>\n' "$*" >> "$LOCAL_CODE_HOST_TEST_LOG"
if [ "$1" = clone ]; then
  for argument in "$@"; do
    destination=$argument
  done
  mkdir -p "$destination/.git"
fi
EOF
cat > "${fake_bin}/cmake" <<'EOF'
#!/bin/sh
printf 'cmake args=<%s>\n' "$*" >> "$LOCAL_CODE_HOST_TEST_LOG"
if [ "$1" = -S ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -B ]; then
      shift
      mkdir -p "$1"
      exit
    fi
    shift
  done
fi
if [ "$1" = --build ]; then
  mkdir -p "$2/bin"
  cp "$LOCAL_CODE_HOST_FAKE_SERVER" "$2/bin/llama-server"
fi
EOF
cat > "${fake_bin}/xcrun" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${fake_bin}/sysctl" <<'EOF'
#!/bin/sh
echo 8
EOF
chmod +x "${fake_bin}/"*

HOME="${tmpdir}/home" \
AI_DIR="${tmpdir}/ai" \
LOCAL_CODE_HOST_TEST_LOG="$log" \
LOCAL_CODE_LLAMA_SERVER="${fake_bin}/llama-server" \
LOCAL_CODE_MODEL_DOWNLOAD="${fake_bin}/model-download" \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/../bin/local-code-host" --model qwen3coder-q5

grep -F "model-download args=<qwen3coder-q5 ${tmpdir}/ai/share/models>" \
  "$log" >/dev/null
grep -F "model-download args=<--path qwen3coder-q5 ${tmpdir}/ai/share/models>" \
  "$log" >/dev/null
grep -F 'Qwen/Qwen3-Coder-Next/resolve/' "$log" >/dev/null
grep -F 'llama-server args=<' "$log" >/dev/null
grep -F -- "--model ${tmpdir}/ai/share/models/model.gguf" "$log" >/dev/null
grep -F -- '--alias qwen3coder-q5 --host 0.0.0.0 --port 8080' "$log" >/dev/null
grep -F -- "--api-key-file ${tmpdir}/ai/share/local-code-host/api-key" \
  "$log" >/dev/null
grep -F -- '--n-gpu-layers 99 --ctx-size 40960' "$log" >/dev/null
grep -F -- "--chat-template-file ${tmpdir}/ai/share/local-code-host/qwen-chat-template.jinja" \
  "$log" >/dev/null
test "$(cat "${tmpdir}/ai/share/local-code-host/api-key")" = test-api-key

line_count=$(wc -l < "$log")
HOME="${tmpdir}/home" \
AI_DIR="${tmpdir}/ai" \
LOCAL_CODE_HOST_TEST_LOG="$log" \
LOCAL_CODE_LLAMA_SERVER="${fake_bin}/llama-server" \
LOCAL_CODE_MODEL_DOWNLOAD="${fake_bin}/model-download" \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/../bin/local-code-host" --model qwen25tiny --download-only
test "$(wc -l < "$log")" -eq $((line_count + 2))

HOME="${tmpdir}/home" \
AI_DIR="${tmpdir}/built-ai" \
LOCAL_CODE_HOST_TEST_LOG="$log" \
LOCAL_CODE_HOST_FAKE_SERVER="${fake_bin}/llama-server" \
LOCAL_CODE_MODEL_DOWNLOAD="${fake_bin}/model-download" \
PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/../bin/local-code-host" --model qwen25tiny
grep -F 'git args=<clone --filter=blob:none --no-checkout' "$log" >/dev/null
grep -F -- '-DGGML_METAL=ON -DLLAMA_CURL=OFF' "$log" >/dev/null
grep -F 'cmake args=<--build ' "$log" | grep -F -- '--target llama-server' >/dev/null

echo 'at=info msg="native local code host tests passed"'
