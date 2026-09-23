#!/bin/bash
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/project with spaces" "$tmpdir/ai/settings"
export MACOS_TEST_LOG="$tmpdir/calls" MACOS_TEST_ARCHIVE="$tmpdir/assets.tar.gz"
cat > "$tmpdir/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac
STUB
cat > "$tmpdir/bin/limactl" <<'STUB'
#!/bin/bash
printf '<%s>' "$@" >> "$MACOS_TEST_LOG"
printf '\n' >> "$MACOS_TEST_LOG"
case "$1" in
  list)
    case "$*" in
      *SSHConfigFile*) echo /tmp/test-ssh-config ;;
      *VMType*) echo vz ;;
      *) [[ "${MACOS_BASE_EXISTS:-0}" == 1 ]] && echo ai-base-macos ;;
    esac
    ;;
  copy) cp "$2" "$MACOS_TEST_ARCHIVE" ;;
  shell)
    if [[ "$*" == *provision.sh* && "${FAIL_PROVISION:-0}" == 1 ]]; then exit 1; fi
    ;;
esac
exit 0
STUB
cat > "$tmpdir/bin/ssh" <<'STUB'
#!/bin/sh
printf '<%s>' "$@" >> "$MACOS_TEST_LOG"
printf '\n' >> "$MACOS_TEST_LOG"
STUB
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
"$REPO_DIR/build_vm" --macos >/dev/null
grep -F '<create><--tty=false><--name><ai-base-macos>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<protect><ai-base-macos>' "$MACOS_TEST_LOG" >/dev/null
tar -tzf "$MACOS_TEST_ARCHIVE" | grep -Fx 'lima/macos/provision.sh' >/dev/null
mkdir "$tmpdir/extracted"
tar -xzf "$MACOS_TEST_ARCHIVE" -C "$tmpdir/extracted"
for asset in lima/assets/claude.sh lima/assets/gitconfig; do
  test -f "$tmpdir/extracted/$asset"
  test ! -L "$tmpdir/extracted/$asset"
  cmp "$REPO_DIR/$asset" "$tmpdir/extracted/$asset"
done
: > "$MACOS_TEST_LOG"
if FAIL_PROVISION=1 "$REPO_DIR/build_vm" --macos >/dev/null 2>&1; then
  echo 'at=fatal msg="failed macOS provisioning was accepted"' >&2
  exit 1
fi
! grep -F '<protect>' "$MACOS_TEST_LOG"
: > "$MACOS_TEST_LOG"
if MACOS_BASE_EXISTS=1 "$REPO_DIR/build_vm" --macos >/dev/null 2>&1; then
  echo 'at=fatal msg="existing macOS base replaced without --force"' >&2
  exit 1
fi
! grep -F '<delete>' "$MACOS_TEST_LOG"
: > "$MACOS_TEST_LOG"
MACOS_BASE_EXISTS=1 "$REPO_DIR/build_vm" --macos --resume >/dev/null
! grep -E '<(create|delete|unprotect)>' "$MACOS_TEST_LOG"
grep -F '<copy>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<protect><ai-base-macos>' "$MACOS_TEST_LOG" >/dev/null
for args in '--resume' '--resume --force'; do
  if "$REPO_DIR/build_vm" --macos $args >/dev/null 2>&1; then
    echo 'at=fatal msg="invalid resume request accepted"' >&2
    exit 1
  fi
done
MACOS_BASE_EXISTS=1 "$REPO_DIR/build_vm" --macos --force >/dev/null
grep -F '<unprotect><ai-base-macos>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<delete><--force><ai-base-macos>' "$MACOS_TEST_LOG" >/dev/null
: > "$MACOS_TEST_LOG"
(
  cd "$tmpdir/project with spaces"
  MACOS_BASE_EXISTS=1 AI_DIR="$tmpdir/ai" AI_VM_HOST_PORT=45555 \
    "$REPO_DIR/bin/ai" --macos cx --ports 9999,8888:7777 >/dev/null
)
grep -F '<ai-base-macos><ai-macos-00-project-with-spaces>' "$MACOS_TEST_LOG" >/dev/null
grep -F '/Users/Shared/ai/app' "$MACOS_TEST_LOG" >/dev/null
grep -F 'bundle-macos' "$MACOS_TEST_LOG" >/dev/null
grep -F '.portForwards = []' "$MACOS_TEST_LOG" >/dev/null
grep -F '<-L><127.0.0.1:45555:127.0.0.1:1337>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<-L><127.0.0.1:8888:127.0.0.1:7777>' "$MACOS_TEST_LOG" >/dev/null
grep -F '</opt/homebrew/bin/bash>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<CODEX_AUTO_START=1>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<-O><exit><lima-ai-macos-00-project-with-spaces>' "$MACOS_TEST_LOG" >/dev/null
grep -F '<delete><--force><ai-macos-00-project-with-spaces>' "$MACOS_TEST_LOG" >/dev/null
! grep -F 'hostnamectl' "$MACOS_TEST_LOG"
if AI_DIR="$tmpdir/ai" "$REPO_DIR/bin/ai" --macos --udp-ports 9999 >/dev/null 2>&1; then
  echo 'at=fatal msg="macOS launcher accepted unsupported UDP forwarding"' >&2
  exit 1
fi
echo 'at=info msg="macOS VM build and launcher tests passed"'
