#!/bin/bash

set -euo pipefail
[[ -z "${BASH_ENV:-}" ]] || exec env -u BASH_ENV bash "$0" "$@"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir "$tmpdir/bin"
# Exercise prerequisite selection without changing the machine's APT sources.
sed '/^download /,$d' "$REPO_DIR/inside_deps/install-chromium.sh" > "$tmpdir/install.sh"
cp "$REPO_DIR/inside_deps/install-utils.sh" "$tmpdir/"
cat > "$tmpdir/bin/dpkg-query" <<'STUB'
#!/bin/bash
case "${*: -1}" in
  libxkbcommon0) printf 'install ok installed' ;;
  *) exit 1 ;;
esac
STUB
cat > "$tmpdir/bin/apt-get" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$APT_LOG"
# Reproduce the reported failure if the installed library is requested again.
[[ " $* " != *' libxkbcommon0 '* ]]
STUB
chmod +x "$tmpdir/bin/"*
printf '%s\n' libxkbcommon0 fonts-liberation > "$tmpdir/packages"
export APT_LOG="$tmpdir/apt.log"
PATH="$tmpdir/bin:$PATH" bash "$tmpdir/install.sh" "$tmpdir/packages"
grep -Fx 'install -y --no-install-recommends fonts-liberation' "$APT_LOG" >/dev/null
: > "$APT_LOG"
printf '%s\n' libxkbcommon0 > "$tmpdir/packages"
PATH="$tmpdir/bin:$PATH" bash "$tmpdir/install.sh" "$tmpdir/packages"
[[ $(cat "$APT_LOG") == update ]]
echo 'at=info msg="Chromium prerequisite tests passed"'
