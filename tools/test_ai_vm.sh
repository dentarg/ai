#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
ai_dir="${tmpdir}/ai"
project="${tmpdir}/project with spaces"
log="${tmpdir}/limactl.log"
mkdir -p "$fake_bin" "$project" "${ai_dir}/settings" "${tmpdir}/home"

# The fake records one shell-quoted argument per line, grouped by invocation.
cat > "${fake_bin}/limactl" <<'EOF'
#!/bin/bash
{
  printf 'CALL'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$LIMACTL_LOG"

case "${1:-}" in
  list) printf '%s\n' ai-base ;;
  shell)
    case "$*" in
      *'/workspace/.ai-op-token'*) cat >/dev/null ;;
    esac
    ;;
esac
EOF
chmod +x "${fake_bin}/limactl"

(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45555 \
  LIMACTL_LOG="$log" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm cx --ports 9999,8888:7777 >/dev/null 2>&1
)

grep -F '<clone>' "$log" >/dev/null
grep -F '<clone> <--tty=false>' "$log" >/dev/null
if grep -F '<--nested-virt>' "$log" >/dev/null; then
  echo 'at=fatal msg="Lima launcher enabled nested virtualization by default"' >&2
  exit 1
fi
grep -F '<ai-base> <ai-00-project-with-spaces>' "$log" >/dev/null
grep -F '.timezone = "UTC"' "$log" >/dev/null
grep -F '<shell> <--workdir> </app> <ai-00-project-with-spaces> <sudo> <hostnamectl> <set-hostname> <ai-00-project-with-spaces>' "$log" >/dev/null
if grep -F '<--yes>' "$log" >/dev/null; then
  echo 'at=fatal msg="Lima launcher used deprecated --yes flag"' >&2
  exit 1
fi
grep -F '"mountPoint":"/app"' "$log" >/dev/null
grep -F '"location":"'"$project"'"' "$log" >/dev/null
grep -F '"guestPort":1337,"hostPort":45555' "$log" >/dev/null
grep -F '"guestPort":9999,"hostPort":9999' "$log" >/dev/null
grep -F '"guestPort":7777,"hostPort":8888' "$log" >/dev/null
grep -F '<AI_AUTO_LAUNCH=1>' "$log" >/dev/null
grep -F '<CODEX_AUTO_START=1>' "$log" >/dev/null
grep -F '<shell> <--workdir> </app>' "$log" >/dev/null
grep -F '<stop>' "$log" >/dev/null
grep -F '<delete> <--force>' "$log" >/dev/null

: > "$log"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45556 \
  LIMACTL_LOG="$log" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --keep-vm >/dev/null 2>&1
)

if grep -F '<delete>' "$log" >/dev/null; then
  echo 'at=fatal msg="--keep-vm deleted the Lima VM"' >&2
  exit 1
fi

: > "$log"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45557 \
  LIMACTL_LOG="$log" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm --nested-virt --cpus 8 --memory=16 >/dev/null 2>&1
)

grep -F '<clone> <--tty=false> <--nested-virt> <--cpus> <8> <--memory> <16>' "$log" >/dev/null

if HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --nested-virt >/dev/null 2>&1; then
  echo 'at=fatal msg="--nested-virt worked without --vm"' >&2
  exit 1
fi

echo 'at=info msg="ai Lima VM launcher tests passed"'
