#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: gh-host pr-list OWNER/REPO
       gh-host pr-view OWNER/REPO NUMBER
       gh-host pr-diff OWNER/REPO NUMBER
       gh-host pr-comments OWNER/REPO NUMBER
       gh-host pr-reviews OWNER/REPO NUMBER
       gh-host pr-review-comments OWNER/REPO NUMBER
       gh-host issue-list OWNER/REPO
       gh-host issue-view OWNER/REPO NUMBER
       gh-host issue-comments OWNER/REPO NUMBER
       gh-host issue-timeline OWNER/REPO NUMBER
       gh-host pr-create OWNER/REPO HEAD BASE TITLE < body.txt

PR creation requires host approval and creates a draft. HEAD must already
exist in the repository. Read operations return GitHub JSON or a diff.
EOF
  exit 2
}

[ "$#" -ge 2 ] || usage
operation=$1
repository=$2
shift 2
case "$operation" in
  pr-list|issue-list)
    [ "$#" -eq 0 ] || usage
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" '{operation:$operation,repository:$repository}')
    ;;
  pr-view|pr-diff|pr-comments|pr-reviews|pr-review-comments|issue-view|issue-comments|issue-timeline)
    [ "$#" -eq 1 ] || usage
    case "$1" in ''|*[!0-9]*) usage ;; esac
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" --arg number "$1" '{operation:$operation,repository:$repository,number:($number|tonumber)}')
    ;;
  pr-create)
    [ "$#" -eq 3 ] || usage
    payload=$(jq -Rsc --arg operation "$operation" --arg repository "$repository" --arg head "$1" --arg base "$2" --arg title "$3" '{operation:$operation,repository:$repository,head:$head,base:$base,title:$title,body:.}')
    ;;
  *) usage ;;
esac

: "${GH_BRIDGE_URL:?gh-host is unavailable; launch bin/ai with --github=PROFILE}"
if [ -z "${GH_BRIDGE_TOKEN:-}" ] && [ -n "${GH_BRIDGE_TOKEN_FILE:-}" ]; then
  GH_BRIDGE_TOKEN=$(cat "$GH_BRIDGE_TOKEN_FILE")
fi
: "${GH_BRIDGE_TOKEN:?GH_BRIDGE_TOKEN is not set}"
: "${GH_BRIDGE_CA:?GH_BRIDGE_CA is not set}"

printf '%s' "$payload" | curl --silent --show-error --fail-with-body \
  --connect-timeout 5 --max-time 200 --noproxy '*' \
  --cacert "$GH_BRIDGE_CA" \
  --header "Authorization: Bearer ${GH_BRIDGE_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-binary @- "${GH_BRIDGE_URL}/v1/github"
