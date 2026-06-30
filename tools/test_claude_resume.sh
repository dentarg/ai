#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/claude.sh
source "${SCRIPT_DIR}/claude.sh"

assert_equal () {
  local expected=$1
  local actual=$2
  local message=$3

  if [[ "$actual" != "$expected" ]]; then
    echo "at=fatal msg=\"${message}\" expected=\"${expected}\" actual=\"${actual}\"" >&2
    exit 1
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

session_id=11111111-2222-4333-8444-555555555555
subagent_id=agent-a1111111111111111
run_dir="${tmpdir}/example_claude"
workspace_dir="${run_dir}/projects/example-workspace"
session_dir="${workspace_dir}/${session_id}"
other_workspace_dir="${tmpdir}/example_gemini/projects/example-workspace"
expected="${workspace_dir}/${session_id}.jsonl"

mkdir -p "$other_workspace_dir"
printf '{}\n' > "${other_workspace_dir}/${session_id}.jsonl"

mkdir -p "${session_dir}/subagents"
printf '{}\n' > "${session_dir}/subagents/${subagent_id}.jsonl"
printf '{}\n' > "$expected"

actual=$(find_resume_jsonl "$tmpdir" "$session_id")
assert_equal "$expected" "$actual" "resume lookup selected wrong transcript"

actual=$(find_resume_jsonl "$tmpdir" "${session_id:0:8}")
assert_equal "$expected" "$actual" "resume prefix lookup selected wrong transcript"

actual=$(find_resume_jsonl "$tmpdir" "$subagent_id" || true)
assert_equal "" "$actual" "resume lookup should ignore subagent transcripts"

echo 'at=info msg="claude resume lookup tests passed"'
