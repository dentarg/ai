#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

project="${tmpdir}/project"
mkdir -p "$project" "${tmpdir}/sessions"

cat > "${project}/calculator.js" <<'EOF'
export function add(left, right) {
  return left - right;
}
EOF

cat > "${project}/calculator.test.js" <<'EOF'
import assert from "node:assert/strict";
import { add } from "./calculator.js";

assert.equal(add(2, 3), 5);
console.log('at=info msg="calculator test passed"');
EOF

cat > "${project}/package.json" <<'EOF'
{
  "type": "module",
  "scripts": {
    "test": "node calculator.test.js"
  }
}
EOF

(
  cd "$project"
  PI_CODING_AGENT_SESSION_DIR="${tmpdir}/sessions" \
  LOCAL_CODE_GUARD_EXTENSION="${SCRIPT_DIR}/pi-local-guard.ts" \
    "${SCRIPT_DIR}/local-code.sh" --print \
      "Fix the calculator implementation so npm test passes. Run the test and finish when it passes."
)

(
  cd "$project"
  npm test
)

grep -F 'return left + right;' "${project}/calculator.js" >/dev/null
echo 'at=info msg="local coding model smoke test passed" model="qwen38"'
