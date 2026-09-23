#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
project="${tmpdir}/project with spaces"
log="${tmpdir}/limactl.log"
mkdir -p "$fake_bin" "$project"

cat > "${fake_bin}/limactl" <<'EOF'
#!/bin/bash
{
  printf 'CALL'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$LIMACTL_LOG"

if [[ "${1:-}" == list && "${2:-}" == --quiet ]]; then
  printf '%s\n' \
    ai-base \
    ai-base-gpu \
    ai-00-other \
    ai-00-project-with-spaces \
    ai-01-project-with-spaces
  if [[ -n "${TEST_VM_NAME:-}" ]]; then
    printf '%s\n' "$TEST_VM_NAME"
  fi
elif [[ "${1:-}" == list && -n "${TEST_VM_NAME:-}" && "${2:-}" == "$TEST_VM_NAME" ]]; then
  printf '%s\n' Running
elif [[ "${1:-}" == list && "${2:-}" == ai-00-project-with-spaces ]]; then
  printf '%s\n' Stopped
elif [[ "${1:-}" == list && "${2:-}" == ai-01-project-with-spaces ]]; then
  printf '%s\n' Running
elif [[ "${1:-}" == list && "${2:-}" == ai-00-other ]]; then
  printf '%s\n' Running
elif [[ "${1:-}" == shell && "$*" == *' infocmp '* ]]; then
  exit "${TERMINFO_STATUS:-0}"
fi
EOF
chmod +x "${fake_bin}/limactl"

(
  cd "$project"
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" "$REPO_DIR/bin/vm"
)
grep -F '<list> <ai-01-project-with-spaces> <--format> <{{.Status}}>' "$log" >/dev/null
if grep -F '<list> <ai-base-gpu> <--format> <{{.Status}}>' "$log" >/dev/null; then
  echo 'at=fatal msg="vm helper inspected an unrelated base VM"' >&2
  exit 1
fi
grep -F '<shell> <--workdir> </app> <ai-01-project-with-spaces> <env> <TERM=' "$log" | \
  grep -F '<bash> <--rcfile> </workspace/.bashrc> <-i>' >/dev/null
if grep -F '<start>' "$log" >/dev/null; then
  echo 'at=fatal msg="vm helper restarted a running VM"' >&2
  exit 1
fi

: > "$log"
LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/bin/vm" ai-00-project-with-spaces uname -a
grep -F '<start> <ai-00-project-with-spaces>' "$log" >/dev/null
grep -F '<shell> <--workdir> </app> <ai-00-project-with-spaces> <env> <TERM=' "$log" | \
  grep -F '<uname> <-a>' >/dev/null

: > "$log"
LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" "$REPO_DIR/bin/vm" last
grep -F '<shell> <--workdir> </app> <ai-01-project-with-spaces>' "$log" >/dev/null

: > "$log"
fallback_output="${tmpdir}/fallback-output"
LIMACTL_LOG="$log" TERM=xterm-ghostty TERMINFO_STATUS=1 \
  PATH="${fake_bin}:${PATH}" "$REPO_DIR/bin/vm" last \
  >"$fallback_output" 2>&1
grep -F '<env> <TERM=xterm-256color>' "$log" >/dev/null
grep -F 'falling back to xterm-256color' "$fallback_output" >/dev/null

for variant in gpu macos; do
  vm_name="ai-${variant}-00-project-with-spaces"
  for mode in current last; do
    : > "$log"
    (
      cd "$project"
      export TEST_VM_NAME="$vm_name" LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}"
      if [[ "$mode" == current ]]; then
        "$REPO_DIR/bin/vm"
      else
        "$REPO_DIR/bin/vm" last
      fi
    )
    grep -F "<shell> <--workdir> </app> <$vm_name>" "$log" >/dev/null
  done
  long_project=$(printf '%060d' 0)
  mkdir -p "$tmpdir/$long_project"
  limit=53
  [[ "$variant" == macos ]] && limit=51
  vm_name="ai-${variant}-00-${long_project:0:$limit}"
  : > "$log"
  (
    cd "$tmpdir/$long_project"
    TEST_VM_NAME="$vm_name" LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" "$REPO_DIR/bin/vm"
  )
  grep -F "<shell> <--workdir> </app> <$vm_name>" "$log" >/dev/null
done

echo 'at=info msg="Lima VM helper tests passed"'
