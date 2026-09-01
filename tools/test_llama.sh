#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/docker.log"
work_dir="${tmpdir}/directory with spaces"
mkdir -p "$fake_bin" "$work_dir"

cat > "${fake_bin}/docker" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$DOCKER_LOG"
EOF
chmod +x "${fake_bin}/docker"
ln -s "${SCRIPT_DIR}/llama.cpp.sh" "${fake_bin}/llama-cli"
ln -s "${SCRIPT_DIR}/llama.cpp.sh" "${fake_bin}/llama-server"

(
  cd "$work_dir"
  DOCKER_LOG="$log" GGML_VK_DISABLE_F16=1 \
    PATH="${fake_bin}:${PATH}" llama-cli --version
)
grep -Fx '<--device>' "$log" >/dev/null
grep -Fx '</dev/dri>' "$log" >/dev/null
grep -Fx '<HOME=/tmp>' "$log" >/dev/null
grep -Fx '<GGML_VK_DISABLE_F16>' "$log" >/dev/null
grep -Fx '<--network>' "$log" >/dev/null
grep -Fx '<host>' "$log" >/dev/null
grep -Fx '<--user>' "$log" >/dev/null
grep -Fx "<${work_dir}:${work_dir}>" "$log" >/dev/null
grep -Fx '<ai-llama.cpp>' "$log" >/dev/null
grep -Fx '<llama-cli>' "$log" >/dev/null
grep -Fx '<--version>' "$log" >/dev/null

(
  cd /share
  DOCKER_LOG="$log" PATH="${fake_bin}:${PATH}" llama-server --version
)
if [[ $(grep -Fc '<--volume>' "$log") -ne 1 ]]; then
  echo 'at=fatal msg="llama wrapper mounted /share more than once"' >&2
  exit 1
fi
grep -Fx '<llama-server>' "$log" >/dev/null

echo 'at=info msg="llama wrapper tests passed"'
