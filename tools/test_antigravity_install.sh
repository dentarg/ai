#!/bin/bash

set -euo pipefail
[[ -z "${BASH_ENV:-}" ]] || exec env -u BASH_ENV bash "$0" "$@"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
mkdir -p "$task_dir/bin" "$task_dir/release"
printf '#!/bin/sh\necho 1.4.7\n' > "$task_dir/release/antigravity"
tar -czf "$task_dir/release.tar.gz" -C "$task_dir/release" antigravity
checksum=$(shasum -a 512 "$task_dir/release.tar.gz" | cut -d ' ' -f 1)
jq -n --arg checksum "$checksum" '{
  version: "1.4.7",
  url: "https://storage.googleapis.com/antigravity-public/antigravity-cli/test.tar.gz",
  sha512: $checksum
} | . as $release | reduce ["linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64"][] as $platform
  ({}; .[$platform] = $release)' > "$task_dir/manifest.json"
cat > "$task_dir/bin/curl" <<'STUB'
#!/bin/sh
while [ "$1" != -o ]; do shift; done
cp "$TEST_RELEASE" "$2"
STUB
cat > "$task_dir/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -s) echo "$TEST_OS" ;; -m) echo "$TEST_ARCH" ;; esac
STUB
chmod +x "$task_dir/bin/"*
export TEST_RELEASE="$task_dir/release.tar.gz" PATH="$task_dir/bin:$PATH"
for TEST_OS in Linux Darwin; do
  for TEST_ARCH in x86_64 arm64; do
    export TEST_OS TEST_ARCH
    bash "$REPO_DIR/inside_deps/_antigravity.sh" "$task_dir/manifest.json" "$task_dir/installed/g"
    test "$("$task_dir/installed/g" --version)" = 1.4.7
  done
done

# Reject corrupt downloads before replacing a working installation.
printf 'Corrupted release\n' > "$task_dir/bad-release"
if TEST_RELEASE="$task_dir/bad-release" \
  bash "$REPO_DIR/inside_deps/_antigravity.sh" "$task_dir/manifest.json" "$task_dir/installed/g" \
  >"$task_dir/error" 2>&1; then
  echo 'Corrupted release was accepted.' >&2
  exit 1
fi
test "$("$task_dir/installed/g" --version)" = 1.4.7

echo 'at=info msg="Antigravity installer tests passed"'
