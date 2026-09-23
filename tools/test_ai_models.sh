#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

ai_dir="${tmpdir}/ai"
mkdir -p "${ai_dir}/settings/codex_alpha" \
  "${ai_dir}/settings/claude_alpha" \
  "${ai_dir}/host-browser/profiles/work"
printf '%s\n' '{}' > "${ai_dir}/settings/claude_alpha/settings.json"
printf '%s\n' '# defaults' > \
  "${ai_dir}/settings/codex_alpha/default.config.toml"

AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" validate codex gpt-6-astra
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" validate claude claude-opus-4-8
if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" \
  validate codex claude-opus-4-8 >/dev/null 2>&1; then
  echo 'at=fatal msg="Codex accepted a Claude model"' >&2
  exit 1
fi
if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" \
  validate claude gpt-6-astra >/dev/null 2>&1; then
  echo 'at=fatal msg="Claude accepted a Codex model"' >&2
  exit 1
fi

AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex gpt-6-astra >/dev/null
if AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" \
  profile set-model alpha codex claude-opus-4-8 >/dev/null 2>&1; then
  echo 'at=fatal msg="profile setter accepted a cross-provider model"' >&2
  exit 1
fi

fixture="${tmpdir}/models.json"
cat > "$fixture" <<'EOF'
[
  {"id":"gpt-test","provider":"openai","family":"gpt-test","pricing":{"text_tokens":{"standard":{"input_per_million":1,"output_per_million":2,"cache_read_input_per_million":0.1}}}},
  {"id":"claude-test","provider":"anthropic","family":"claude-test","pricing":{"text_tokens":{"standard":{"input_per_million":3,"output_per_million":4,"cache_read_input_per_million":0.3,"cache_write_input_per_million":3.75}}}},
  {"id":"gemini-test","provider":"google","pricing":{}}
]
EOF
AI_DIR="$ai_dir" AI_MODELS_URL="file://${fixture}" \
  "$REPO_DIR/bin/ai-models" refresh >/dev/null
cache="${ai_dir}/cache/models.json"
jq -e '.models | length == 2' "$cache" >/dev/null
jq -e '.models[] | select(.id == "gpt-test") | .pricing.input == 1' \
  "$cache" >/dev/null
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" validate codex gpt-test
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai-models" validate claude claude-test

completion=$(AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" completion bash)
eval "$completion"
PATH="$REPO_DIR/bin:$PATH"
COMP_WORDS=(ai pro)
COMP_CWORD=1
_ai_complete
[[ ${COMPREPLY[*]} == profile ]]
COMP_WORDS=(ai profile set)
COMP_CWORD=2
_ai_complete
[[ ${COMPREPLY[*]} == set-model ]]
COMP_WORDS=(ai profile rem)
COMP_CWORD=2
_ai_complete
[[ ${COMPREPLY[*]} == remove ]]
COMP_WORDS=(ai --host-browser=w)
COMP_CWORD=1
AI_DIR="$ai_dir" _ai_complete
[[ ${COMPREPLY[*]} == --host-browser=work ]]
COMP_WORDS=("$REPO_DIR/bin/ai" profile set-model alpha codex gpt-)
COMP_CWORD=5
AI_DIR="$ai_dir" _ai_complete
printf '%s\n' "${COMPREPLY[@]}" | grep -Fx gpt-test >/dev/null
if printf '%s\n' "${COMPREPLY[@]}" | grep -Fx claude-test >/dev/null; then
  echo 'at=fatal msg="Codex completion included a Claude model"' >&2
  exit 1
fi
AI_DIR="$ai_dir" "$REPO_DIR/bin/ai" completion zsh | zsh -n
AI_DIR="$ai_dir" REPO_DIR="$REPO_DIR" zsh -dfc '
  source <("$REPO_DIR/bin/ai" completion zsh)
  [[ ${_comps[ai]:-} == _ai ]]
  typeset -a words
  compadd() { print -r -- "$@"; }
  _values() { print -r -- "$@"; }
  words=(ai pro)
  CURRENT=2
  candidates=("${(@f)$(_ai)}")
  [[ $candidates[1] == *ai-arguments*profile*--host-browser* ]]
  [[ $candidates[1] == *--host-browser=work* ]]
  words=(ai profile set)
  CURRENT=3
  [[ $(_ai) == *set-model* ]]
'

echo 'at=info msg="ai model catalog tests passed"'
