#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/limactl.log"
captured_template="${tmpdir}/ai.lima.yaml"
captured_archives="${tmpdir}/archives"
mkdir -p "$fake_bin"
mkdir -p "$captured_archives"

cat > "${fake_bin}/limactl" <<'EOF'
#!/bin/bash
printf '<%s>' "$@" >> "$LIMACTL_LOG"
printf '\n' >> "$LIMACTL_LOG"
if [[ "${1:-}" == list && "${BASE_EXISTS:-0}" == 1 ]]; then
  printf '%s\n' ai-base
fi
if [[ "${1:-}" == info ]]; then
  printf '%s\n' '{"vmTypesEx":{"krunkit":{"location":"/fake/krunkit"}}}'
fi
if [[ "${1:-}" == validate ]]; then
  cp "$2" "$CAPTURED_TEMPLATE"
  while IFS= read -r archive; do
    cp "$archive" "$CAPTURED_ARCHIVES/$(basename "$archive")"
  done < <(sed -n 's/^[[:space:]]*file: "\(.*ai-build-[^\"]*\.tar\.gz\.b64\)"$/\1/p' "$2")
fi
EOF
chmod +x "${fake_bin}/limactl"
cat > "${fake_bin}/krunkit" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${fake_bin}/krunkit"

CAPTURED_TEMPLATE="$captured_template" CAPTURED_ARCHIVES="$captured_archives" \
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" "$REPO_DIR/build_vm" >/dev/null
grep -F '<validate><' "$log" >/dev/null
grep -F '<create><--tty=false><--name><ai-base><--cpus><4><--memory><8><--disk><100>' "$log" >/dev/null
grep -F '<start><--progress><--timeout><60m><ai-base>' "$log" >/dev/null
grep -F '<stop><ai-base>' "$log" >/dev/null
grep -F '<protect><ai-base>' "$log" >/dev/null
if grep -F '@AI_BUILD_' "$captured_template" >/dev/null; then
  echo 'at=fatal msg="build_vm did not resolve the asset archive placeholder"' >&2
  exit 1
fi
grep -F 'AI_VM_USER="{{.User}}" exec bash /tmp/ai-build/provision.sh' \
  "$captured_template" >/dev/null
grep -F 'timezone: UTC' "$captured_template" >/dev/null
if grep -F 'mode: readiness' "$captured_template" >/dev/null; then
  echo 'at=fatal msg="build_vm readiness probe would delay provisioning failures"' >&2
  exit 1
fi

archive_dir="${tmpdir}/archive"
mkdir -p "$archive_dir"
for archive in "$captured_archives"/*.tar.gz.b64; do
  base64 -d < "$archive" | tar -xzf - -C "$archive_dir"
done
while read -r destination source archive; do
  case "$destination" in
    ''|'#'*) continue ;;
  esac
  cmp "$REPO_DIR/$source" "$archive_dir/$destination"
done < "$REPO_DIR/lima/assets/manifest.txt"

if BASE_EXISTS=1 CAPTURED_TEMPLATE="$captured_template" CAPTURED_ARCHIVES="$captured_archives" \
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/build_vm" >/dev/null 2>&1; then
  echo 'at=fatal msg="build_vm replaced an existing base without --force"' >&2
  exit 1
fi

: > "$log"
BASE_EXISTS=1 CAPTURED_TEMPLATE="$captured_template" CAPTURED_ARCHIVES="$captured_archives" \
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/build_vm" --force >/dev/null
grep -F '<unprotect><ai-base>' "$log" >/dev/null
grep -F '<delete><--force><ai-base>' "$log" >/dev/null

: > "$log"
AI_VM_BUILD_TIMEOUT=90m CAPTURED_TEMPLATE="$captured_template" CAPTURED_ARCHIVES="$captured_archives" \
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/build_vm" >/dev/null
grep -F '<start><--progress><--timeout><90m><ai-base>' "$log" >/dev/null

: > "$log"
CAPTURED_TEMPLATE="$captured_template" CAPTURED_ARCHIVES="$captured_archives" \
  LIMACTL_LOG="$log" PATH="${fake_bin}:${PATH}" \
  "$REPO_DIR/build_vm" --gpu >/dev/null
grep -F '<info>' "$log" >/dev/null
grep -F '<create><--tty=false><--vm-type><krunkit><--name><ai-base-gpu>' "$log" >/dev/null
grep -F '<start><--progress><--timeout><60m><ai-base-gpu>' "$log" >/dev/null
grep -F '<stop><ai-base-gpu>' "$log" >/dev/null
grep -F '<protect><ai-base-gpu>' "$log" >/dev/null
grep -F '<AI_VM_GPU=1>' "$log" >/dev/null
grep -F 'test -c /dev/dri/renderD128' "$log" >/dev/null
grep -F 'test -s /workspace/.bashrc' "$log" >/dev/null
grep -F 'test -s /usr/local/bin/cx' "$log" >/dev/null
grep -F 'test -s /usr/local/bin/x' "$log" >/dev/null
grep -F 'alias x=exit' "$log" >/dev/null
grep -F 'swapon --show=NAME --noheadings' "$log" >/dev/null
grep -F 'sync' "$log" >/dev/null
if [[ $(grep -Fc '<start><--timeout><60m><ai-base-gpu>' "$log") -ne 1 ]]; then
  echo 'at=fatal msg="build_vm did not restart the GPU base for persistence verification"' >&2
  exit 1
fi
if [[ $(grep -Fc '<stop><ai-base-gpu>' "$log") -ne 2 ]]; then
  echo 'at=fatal msg="build_vm did not stop the GPU base after persistence verification"' >&2
  exit 1
fi

echo 'at=info msg="build_vm tests passed"'
