#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
download_dir="${tmpdir}/models with spaces"
curl_log="${tmpdir}/curl.log"
mkdir -p "$fake_bin"

cat > "${fake_bin}/curl" <<'EOF'
#!/bin/sh

output=
url=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    output=$2
    shift 2
    continue
  fi
  url=$1
  shift
done

case "$(basename "$output" .part)" in
  Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf) size=17813589920 ;;
  Qwen3-Coder-Next-Q5_K_M-00002-of-00004.gguf) size=17479501728 ;;
  Qwen3-Coder-Next-Q5_K_M-00003-of-00004.gguf) size=17226413600 ;;
  Qwen3-Coder-Next-Q5_K_M-00004-of-00004.gguf) size=4190867520 ;;
  gemma-4-26B_q4_0-it.gguf) size=14439363584 ;;
  Qwen3.6-27B-Q5_K_M.gguf) size=19509790944 ;;
  qwen2.5-0.5b-instruct-q4_k_m.gguf) size=491400032 ;;
  *) exit 1 ;;
esac

printf '%s|%s\n' "$output" "$url" >> "$MODEL_DOWNLOAD_TEST_LOG"
dd if=/dev/zero of="$output" bs=1 count=0 seek="$size" 2>/dev/null
EOF
chmod +x "${fake_bin}/curl"

list=$("$SCRIPT_DIR/model-download" --list)
grep -F 'qwen3coder  Qwen3-Coder-Next 80B-A3B Q5_K_M' <<< "$list" >/dev/null
grep -F 'gemma4      Gemma 4 26B-A4B Q4_0' <<< "$list" >/dev/null
grep -F 'qwen36      Qwen3.6 27B Q5_K_M' <<< "$list" >/dev/null
grep -F 'qwen25tiny  Qwen2.5 0.5B Instruct Q4_K_M' <<< "$list" >/dev/null

MODEL_DOWNLOAD_TEST_LOG="$curl_log" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/model-download" qwen25tiny "$download_dir" >/dev/null

model="${download_dir}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
test "$(wc -c < "$model" | tr -d '[:space:]')" = 491400032
test ! -e "${model}.part"
grep -F "${model}.part|https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  "$curl_log" >/dev/null

MODEL_DOWNLOAD_TEST_LOG="$curl_log" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/model-download" qwen25tiny "$download_dir" >/dev/null
test "$(wc -l < "$curl_log" | tr -d '[:space:]')" = 1

MODEL_DOWNLOAD_TEST_LOG="$curl_log" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/model-download" qwen3coder "${tmpdir}/qwen" >/dev/null
test "$(find "${tmpdir}/qwen" -name '*.gguf' | wc -l | tr -d '[:space:]')" = 4
grep -F 'https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF/resolve/b82fb7382639d97b38fa7672e526c760c2fb358e/Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00004-of-00004.gguf' \
  "$curl_log" >/dev/null

MODEL_DOWNLOAD_TEST_LOG="$curl_log" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/model-download" gemma4 "${tmpdir}/gemma" >/dev/null
grep -F 'https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/d1c082be9cf3c8a514acf63b8761f4b41935842e/gemma-4-26B_q4_0-it.gguf' \
  "$curl_log" >/dev/null

MODEL_DOWNLOAD_TEST_LOG="$curl_log" PATH="${fake_bin}:${PATH}" \
  "$SCRIPT_DIR/model-download" qwen36 "${tmpdir}/qwen36" >/dev/null
grep -F 'https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-Q5_K_M.gguf' \
  "$curl_log" >/dev/null

if "$SCRIPT_DIR/model-download" unknown "$download_dir" >/dev/null 2>&1; then
  echo 'at=fatal msg="model-download accepted an unknown alias"' >&2
  exit 1
fi

echo 'at=info msg="model-download tests passed"'
