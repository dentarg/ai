#!/bin/sh
set -eu
REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "${REPO_DIR}/tools/build-common.sh"
FORCE=0
RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --macos) ;;
    --force) FORCE=1 ;;
    --resume) RESUME=1 ;;
    --update-claude) update_claude_version ;;
    --update-codex) update_codex_version ;;
    --update-plugins) update_plugin_manifest "$REPO_DIR/versions/codex-plugins" ;;
    --update-agents)
      update_claude_version
      update_codex_version
      update_plugin_manifest "$REPO_DIR/versions/codex-plugins"
      ;;
    -h|--help)
      echo 'Usage: ./build_vm --macos [--force | --resume] [--update-agents]'
      exit 0
      ;;
    *) echo "at=fatal msg=\"unsupported macOS build option\" option=$1" >&2; exit 1 ;;
  esac
  shift
done
if [ "$FORCE" -eq 1 ] && [ "$RESUME" -eq 1 ]; then
  echo 'at=fatal msg="--force and --resume cannot be combined"' >&2
  exit 1
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'at=fatal msg="macOS VMs require an Apple-silicon Mac"' >&2
  exit 1
fi
command -v limactl >/dev/null 2>&1 || {
  echo 'at=fatal msg="limactl >= 2.1 is required"' >&2
  exit 1
}
BASE_NAME=${AI_VM_BASE:-ai-base-macos}
BUILD_TIMEOUT=${AI_VM_BUILD_TIMEOUT:-60m}
limactl validate "$REPO_DIR/ai.macos.lima.yaml"
exists=0
if limactl list --format '{{.Name}}' | grep -Fx "$BASE_NAME" >/dev/null; then
  exists=1
  if [ "$FORCE" -ne 1 ] && [ "$RESUME" -ne 1 ]; then
    echo 'at=fatal msg="base VM exists; use --resume to continue or --force to rebuild"' >&2
    exit 1
  fi
  if [ "$FORCE" -eq 1 ]; then
    limactl unprotect "$BASE_NAME"
    limactl delete --force "$BASE_NAME"
  fi
fi
if [ "$RESUME" -eq 1 ] && [ "$exists" -eq 0 ]; then
  echo 'at=fatal msg="no existing macOS base VM to resume"' >&2
  exit 1
fi
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-macos-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM
# Dereference installer/config symlinks whose targets are outside the archive.
COPYFILE_DISABLE=1 tar -chzf "$build_dir/assets.tar.gz" -C "$REPO_DIR" \
  lima/macos lima/assets/claude.sh lima/assets/gitconfig \
  dot.bashrc gitignore-global versions inside_deps/_codex_plugins.sh \
  inside_deps/npm-packages.txt tools/claude.sh tools/codex.sh tools/gemini.sh \
  tools/claude-hook.sh tools/claude-permission-hook.sh tools/claude-login.sh \
  tools/op-read.sh tools/exit.sh bin/codex-login bin/refresh-tokens
if [ "$RESUME" -ne 1 ]; then
  limactl create --tty=false --name "$BASE_NAME" \
    --cpus "${AI_VM_CPUS:-4}" --memory "${AI_VM_MEMORY:-8}" \
    --disk "${AI_VM_DISK:-100}" "$REPO_DIR/ai.macos.lima.yaml"
fi
limactl start --tty=false --timeout "$BUILD_TIMEOUT" "$BASE_NAME"
# Synthetic root links become available at the next boot.
limactl stop "$BASE_NAME"
limactl start --tty=false --timeout "$BUILD_TIMEOUT" "$BASE_NAME"
limactl copy "$build_dir/assets.tar.gz" "$BASE_NAME:/tmp/ai-macos-assets.tar.gz"
limactl shell --workdir /tmp "$BASE_NAME" bash -c '
  set -eu
  test "$(uname -s)" = Darwin
  test -f /var/db/ai-macos-bootstrap
  rm -rf /tmp/ai-macos-build
  mkdir -p /tmp/ai-macos-build
  tar -xzf /tmp/ai-macos-assets.tar.gz -C /tmp/ai-macos-build
  bash /tmp/ai-macos-build/lima/macos/provision.sh
'
limactl stop "$BASE_NAME"
limactl start --tty=false --timeout "$BUILD_TIMEOUT" "$BASE_NAME"
limactl shell --workdir /workspace "$BASE_NAME" bash -lc '
  set -eu
  test -f /workspace/.ai-macos-provisioned
  test -s /workspace/.bashrc
  test -x /usr/local/bin/cx
  test -L /app
  sudo -n true
  /opt/homebrew/bin/bash --version
  claude --version
  codex --version
  ruby --version
  sync
'
limactl stop "$BASE_NAME"
limactl protect "$BASE_NAME"
echo "at=info msg=\"macOS base VM ready\" vm=$BASE_NAME"
