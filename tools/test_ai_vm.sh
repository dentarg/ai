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
ghostty_resources="${tmpdir}/ghostty/share/ghostty"
mkdir -p \
  "$fake_bin" \
  "$project" \
  "${ai_dir}/settings" \
  "${tmpdir}/home" \
  "${tmpdir}/ghostty/share/terminfo" \
  "$ghostty_resources"

cat > "${fake_bin}/infocmp" <<'EOF'
#!/bin/sh
[ "${INFOCMP_STATUS:-0}" -eq 0 ] || exit "$INFOCMP_STATUS"
[ "$1" = -x ] || exit 1
[ "${2:-}" = -A ] || exit 1
printf '%s\n' 'xterm-ghostty|Ghostty,' '  colors#256,'
EOF
chmod +x "${fake_bin}/infocmp"

# The fake records one shell-quoted argument per line, grouped by invocation.
cat > "${fake_bin}/limactl" <<'EOF'
#!/bin/bash
{
  printf 'CALL'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$LIMACTL_LOG"

case "${1:-}" in
  list)
    if [[ "$*" == *'{{.VMType}}'* ]]; then
      case "$2" in
        ai-base-gpu) printf '%s\n' krunkit ;;
        *) printf '%s\n' "${BASE_VM_TYPE:-vz}" ;;
      esac
    else
      printf '%s\n' ai-base ai-base-gpu
    fi
    ;;
  shell)
    case "$*" in
      *'/workspace/.ai-op-token'*) cat >/dev/null ;;
      *'tic -x'*)
        cat >/dev/null
        echo 'terminfo setup noise' >&2
        ;;
    esac
    if [[ "$*" == *AI_AUTO_LAUNCH=1* && "${SHELL_STATUS:-0}" -ne 0 ]]; then
      exit "$SHELL_STATUS"
    fi
    ;;
esac
EOF
chmod +x "${fake_bin}/limactl"

cat > "${fake_bin}/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
cat > "${fake_bin}/chrome-canary" <<'EOF'
#!/bin/sh
for argument do
  case "$argument" in
    --user-data-dir=*) profile=${argument#--user-data-dir=} ;;
  esac
done
mkdir -p "$profile"
printf '9222\n/devtools/browser/test\n' > "${profile}/DevToolsActivePort"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${fake_bin}/uname" "${fake_bin}/chrome-canary"

launch_output="${tmpdir}/launch-output"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_CHROME_CANARY_PATH="${fake_bin}/chrome-canary" \
  AI_VM_HOST_PORT=45555 \
  GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
  LIMACTL_LOG="$log" \
  TERM=xterm-ghostty \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm cx --host-browser --ports 9999,8888:7777 \
    --udp-ports 41642:41641 >"$launch_output" 2>&1
)

if grep -F 'terminfo setup noise' "$launch_output" >/dev/null; then
  echo 'at=fatal msg="successful terminfo installation was noisy"' >&2
  exit 1
fi
grep -F '<clone>' "$log" | grep -F '<--network=vzNAT>' >/dev/null
grep -F '<clone> <--tty=false>' "$log" >/dev/null
if grep -F '<--nested-virt>' "$log" >/dev/null; then
  echo 'at=fatal msg="Lima launcher enabled nested virtualization by default"' >&2
  exit 1
fi
grep -F '<ai-base> <ai-00-project-with-spaces>' "$log" >/dev/null
grep -F '.timezone = "UTC"' "$log" >/dev/null
grep -F '<shell> <--workdir> </app> <ai-00-project-with-spaces> <sudo> <hostnamectl> <set-hostname> <ai-00-project-with-spaces>' "$log" >/dev/null
grep -F '<shell> <--workdir> </app> <ai-00-project-with-spaces> <--> <sudo> <tic> <-x> <-o> </etc/terminfo> </dev/stdin>' "$log" >/dev/null
grep -F '<TERM=xterm-ghostty>' "$log" >/dev/null
if grep -F '<--yes>' "$log" >/dev/null; then
  echo 'at=fatal msg="Lima launcher used deprecated --yes flag"' >&2
  exit 1
fi
grep -F '"mountPoint":"/app"' "$log" >/dev/null
if grep -F '"mountPoint":"/host-workdir/' "$log" >/dev/null; then
  echo 'at=fatal msg="project was mounted at a second VM working directory"' >&2
  exit 1
fi
grep -F '"mountPoint":"/run/host-browser"' "$log" >/dev/null
grep -F '"location":"'"$project"'"' "$log" >/dev/null
grep -F '"guestPort":1337,"hostPort":45555' "$log" >/dev/null
grep -F '"guestPort":9999,"hostPort":9999' "$log" >/dev/null
grep -F '"guestPort":7777,"hostPort":8888' "$log" >/dev/null
grep -F '"guestPort":41641,"hostPort":41642,"guestIP":"0.0.0.0","hostIP":"0.0.0.0","proto":"udp"' "$log" >/dev/null
grep -F '<AI_AUTO_LAUNCH=1>' "$log" >/dev/null
grep -F '<CODEX_AUTO_START=1>' "$log" >/dev/null
grep -F '<HOST_BROWSER_URL=https://host.lima.internal:' "$log" >/dev/null
grep -F '<HOST_BROWSER_CA=/run/host-browser/ca.pem>' "$log" >/dev/null
grep -F '<NODE_EXTRA_CA_CERTS=/run/host-browser/ca.pem>' "$log" >/dev/null
grep -F '<HOST_BROWSER_TOKEN_FILE=/workspace/.ai-host-browser-token>' "$log" >/dev/null
grep -F '/workspace/.ai-host-browser-token' "$log" >/dev/null
grep -F '<shell> <--workdir> </app>' "$log" >/dev/null
grep -F 'Lima clone is missing the provisioned shell or tools' "$log" >/dev/null
grep -F '<stop>' "$log" >/dev/null
grep -F '<delete> <--force>' "$log" >/dev/null

: > "$log"
fallback_output="${tmpdir}/fallback-output"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45560 \
  INFOCMP_STATUS=1 \
  LIMACTL_LOG="$log" \
  TERM=xterm-ghostty \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm >"$fallback_output" 2>&1
)
grep -F '<TERM=xterm-256color>' "$log" >/dev/null
grep -F 'falling back to xterm-256color' "$fallback_output" >/dev/null
if grep -F '<tic>' "$log" >/dev/null; then
  echo 'at=fatal msg="terminfo compilation ran without a source"' >&2
  exit 1
fi

: > "$log"
failure_output="${tmpdir}/failure-output"
if (
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45559 \
  LIMACTL_LOG="$log" \
  SHELL_STATUS=137 \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm >"$failure_output" 2>&1
); then
  echo 'at=fatal msg="failed Lima console returned success"' >&2
  exit 1
fi
if grep -F '"proto":"udp"' "$log" >/dev/null; then
  echo 'at=fatal msg="UDP forwarding was enabled without --udp-ports"' >&2
  exit 1
fi
if grep -F '<stop>' "$log" >/dev/null || grep -F '<delete>' "$log" >/dev/null; then
  echo 'at=fatal msg="failed Lima console was not retained"' >&2
  exit 1
fi
grep -F 'keeping Lima VM after abnormal console exit' "$failure_output" >/dev/null
grep -F 'status=137' "$failure_output" >/dev/null
grep -F 'limactl delete --force ai-00-project-with-spaces' "$failure_output" >/dev/null

: > "$log"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45556 \
  BASE_VM_TYPE=qemu \
  LIMACTL_LOG="$log" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --keep-vm >/dev/null 2>&1
)

if grep -F '<delete>' "$log" >/dev/null; then
  echo 'at=fatal msg="--keep-vm deleted the Lima VM"' >&2
  exit 1
fi
if grep -F '<--network=vzNAT>' "$log" >/dev/null; then
  echo 'at=fatal msg="vzNAT was enabled for QEMU"' >&2
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

: > "$log"
(
  cd "$project"
  HOME="${tmpdir}/home" \
  AI_DIR="$ai_dir" \
  AI_VM_HOST_PORT=45558 \
  LIMACTL_LOG="$log" \
  PATH="${fake_bin}:${PATH}" \
    "$REPO_DIR/bin/ai" --vm --gpu >/dev/null 2>&1
)

grep -F '<clone> <--tty=false>' "$log" | \
  grep -F '<ai-base-gpu> <ai-00-project-with-spaces>' >/dev/null

if grep -F '<--network=vzNAT>' "$log" >/dev/null; then
  echo 'at=fatal msg="vzNAT was enabled for krunkit"' >&2
  exit 1
fi

if HOME="${tmpdir}/home" AI_DIR="$ai_dir" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/ai" --gpu >/dev/null 2>&1; then
  echo 'at=fatal msg="--gpu worked without --vm"' >&2
  exit 1
fi

echo 'at=info msg="ai Lima VM launcher tests passed"'
