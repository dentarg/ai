#!/bin/bash

set -euo pipefail
# BASH_ENV startup files reset HOME and install a DEBUG trap that
# rewrites PATH, defeating fake homes and stubbed commands.
[[ -z "${BASH_ENV:-}" ]] || exec env -u BASH_ENV bash "$0" "$@"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
log="${tmpdir}/commands.log"
mkdir -p "$fake_bin" "${tmpdir}/project"

cat > "${fake_bin}/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl <%s>\n' "$*" >> "$COMMAND_LOG"
EOF
chmod +x "${fake_bin}/systemctl"

output=$(
  cd "${tmpdir}/project"
  COMMAND_LOG="$log" PATH="${fake_bin}:${PATH}" bash "$REPO_DIR/tools/start.sh" 2>&1
)

for service in PostgreSQL LavinMQ Redis; do
  grep -F "+ Starting ${service}..." <<< "$output" >/dev/null
done
grep -F '+ Skipping bundle install (Gemfile not found).' <<< "$output" >/dev/null
[[ $(wc -l <<< "$output") -eq 4 ]]
[[ $(wc -l < "$log") -eq 3 ]]

echo 'at=info msg="sandbox service launcher tests passed"'
