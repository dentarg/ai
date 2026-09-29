#!/bin/bash
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"
export XCODE_TEST_LOG="$tmpdir/calls"
cat > "$tmpdir/bin/sudo" <<'STUB'
#!/bin/sh
exec "$@"
STUB
cat > "$tmpdir/bin/xcodebuild" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$XCODE_TEST_LOG"
if [ "$1" = -runFirstLaunch ]; then exit "${XCODE_TEST_FAIL:-0}"; fi
STUB
cp "$tmpdir/bin/xcodebuild" "$tmpdir/bin/xcode-select"
cp "$tmpdir/bin/xcodebuild" "$tmpdir/bin/xcrun"
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
bash "$REPO_DIR/lima/macos/xcode.sh"
cat > "$tmpdir/expected" <<'EXPECTED'
--switch /Applications/Xcode.app/Contents/Developer
-license accept
-runFirstLaunch
-downloadPlatform iOS
--sdk macosx --show-sdk-path
--sdk iphoneos --show-sdk-path
--sdk iphonesimulator --show-sdk-path
simctl list runtimes
EXPECTED
diff -u "$tmpdir/expected" "$XCODE_TEST_LOG"
: > "$XCODE_TEST_LOG"
if XCODE_TEST_FAIL=1 bash "$REPO_DIR/lima/macos/xcode.sh"; then
  echo 'at=fatal msg="Xcode initialization failure was ignored"' >&2
  exit 1
fi
! grep -F -- '-downloadPlatform' "$XCODE_TEST_LOG"
echo 'at=info msg="macOS Xcode setup tests passed"'
