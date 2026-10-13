#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: gh-host pr-list OWNER/REPO
       gh-host pr-view OWNER/REPO NUMBER
       gh-host pr-diff OWNER/REPO NUMBER
       gh-host pr-comments OWNER/REPO NUMBER
       gh-host pr-comment OWNER/REPO NUMBER < body.txt
       gh-host pr-reviews OWNER/REPO NUMBER
       gh-host pr-review-comments OWNER/REPO NUMBER
       gh-host pr-review-threads OWNER/REPO NUMBER
       gh-host pr-review-reply OWNER/REPO NUMBER THREAD_ID < body.txt
       gh-host pr-review-resolve OWNER/REPO NUMBER THREAD_ID
       gh-host issue-list OWNER/REPO
       gh-host issue-view OWNER/REPO NUMBER
       gh-host issue-comments OWNER/REPO NUMBER
       gh-host issue-timeline OWNER/REPO NUMBER
       gh-host issue-create OWNER/REPO TITLE < body.txt
       gh-host pr-create OWNER/REPO HEAD BASE TITLE < body.txt
       gh-host pr-edit-body OWNER/REPO NUMBER < body.txt
       gh-host asset-upload OWNER/REPO FILE
       gh-host run-list OWNER/REPO [HEAD_SHA]
       gh-host run-view OWNER/REPO RUN_ID
       gh-host run-jobs OWNER/REPO RUN_ID
       gh-host job-log OWNER/REPO JOB_ID
       gh-host run-artifacts OWNER/REPO RUN_ID
       gh-host run-logs OWNER/REPO RUN_ID FILE.zip
       gh-host artifact-download OWNER/REPO ARTIFACT_ID FILE

PR creation requires host approval and creates a draft. HEAD must already
exist in the repository. All write operations require host approval.
Read operations return GitHub JSON or a diff.
Asset uploads return JSON with url and markdown for use in text bodies.
CI reads return JSON or job log text. Downloads are saved to a new local file.
EOF
  exit 2
}

[ "$#" -ge 2 ] || usage
operation=$1
repository=$2
shift 2
case "$operation" in
  run-list)
    [ "$#" -le 1 ] || usage
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" '{operation:$operation,repository:$repository}')
    if [ "$#" -eq 1 ]; then
      payload=$(printf '%s' "$payload" | jq -c --arg sha "$1" '. + {head_sha:$sha}')
    fi
    ;;
  run-view|run-jobs|job-log|run-artifacts|run-logs|artifact-download)
    case "$operation" in
      run-logs|artifact-download)
        [ "$#" -eq 2 ] || usage
        download_file=$2
        [ -n "$download_file" ] && [ "$download_file" != - ] || usage
        case "$download_file" in /*) ;; *) download_file="./$download_file" ;; esac
        if [ -e "$download_file" ] || [ -L "$download_file" ]; then
          echo 'Download destination already exists' >&2
          exit 2
        fi
        request_timeout=240
        ;;
      *) [ "$#" -eq 1 ] || usage ;;
    esac
    case "$1" in ''|*[!0-9]*) usage ;; esac
    case "$operation" in
      job-log) id_key=job_id ;;
      artifact-download) id_key=artifact_id ;;
      *) id_key=run_id ;;
    esac
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" --arg key "$id_key" --arg id "$1" '{operation:$operation,repository:$repository} + {($key):($id|tonumber)}')
    ;;
  asset-upload)
    request_timeout=360
    [ "$#" -eq 1 ] || usage
    asset_file=$1
    [ -f "$asset_file" ] || { echo 'Asset must be a regular file' >&2; exit 2; }
    case "$repository" in ''|*[!A-Za-z0-9_./-]*) usage ;; esac
    extension=$(printf '%s' "${asset_file##*.}" | tr '[:upper:]' '[:lower:]')
    case "$extension" in
      png) content_type=image/png ;;
      jpg|jpeg) content_type=image/jpeg ;;
      gif) content_type=image/gif ;;
      webp) content_type=image/webp ;;
      svg) content_type=image/svg+xml ;;
      mp4) content_type=video/mp4 ;;
      mov) content_type=video/quicktime ;;
      webm) content_type=video/webm ;;
      *) echo 'Unsupported asset type: use PNG, JPEG, GIF, WebP, SVG, MP4, MOV, or WebM' >&2; exit 2 ;;
    esac
    maximum=10485760
    case "$content_type" in video/*) maximum=104857600 ;; esac
    size=$(wc -c < "$asset_file" | tr -d '[:space:]')
    if [ "$size" -eq 0 ] || [ "$size" -gt "$maximum" ]; then
      echo "Asset must contain between 1 and $maximum bytes" >&2
      exit 2
    fi
    asset_name=$(jq -rn --arg name "${asset_file##*/}" '$name | @uri')
    ;;
  pr-list|issue-list)
    [ "$#" -eq 0 ] || usage
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" '{operation:$operation,repository:$repository}')
    ;;
  pr-view|pr-diff|pr-comments|pr-reviews|pr-review-comments|pr-review-threads|issue-view|issue-comments|issue-timeline)
    [ "$#" -eq 1 ] || usage
    case "$1" in ''|*[!0-9]*) usage ;; esac
    payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" --arg number "$1" '{operation:$operation,repository:$repository,number:($number|tonumber)}')
    ;;
  pr-review-reply|pr-review-resolve)
    [ "$#" -eq 2 ] || usage
    case "$1" in ''|*[!0-9]*) usage ;; esac
    if [ "$operation" = pr-review-reply ]; then
      payload=$(jq -Rsc --arg operation "$operation" --arg repository "$repository" --arg number "$1" --arg thread_id "$2" '{operation:$operation,repository:$repository,number:($number|tonumber),thread_id:$thread_id,body:.}')
    else
      payload=$(jq -cn --arg operation "$operation" --arg repository "$repository" --arg number "$1" --arg thread_id "$2" '{operation:$operation,repository:$repository,number:($number|tonumber),thread_id:$thread_id}')
    fi
    ;;
  pr-edit-body|pr-comment)
    [ "$#" -eq 1 ] || usage
    case "$1" in ''|*[!0-9]*) usage ;; esac
    payload=$(jq -Rsc --arg operation "$operation" --arg repository "$repository" --arg number "$1" '{operation:$operation,repository:$repository,number:($number|tonumber),body:.}')
    ;;
  issue-create)
    [ "$#" -eq 1 ] || usage
    payload=$(jq -Rsc --arg operation "$operation" --arg repository "$repository" --arg title "$1" '{operation:$operation,repository:$repository,title:$title,body:.}')
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

bridge_request() {
  curl --silent --show-error --fail-with-body \
    --connect-timeout 5 --max-time "${request_timeout:-200}" --noproxy '*' \
    --cacert "$GH_BRIDGE_CA" \
    --header "Authorization: Bearer ${GH_BRIDGE_TOKEN}" \
    --header 'Expect:' "$@"
}

if [ "$operation" = run-logs ] || [ "$operation" = artifact-download ]; then
  download_temp=$(mktemp "$(dirname "$download_file")/.gh-host-download.XXXXXX")
  trap 'rm -f "$download_temp"' 0
  trap 'exit 1' 1 2 15
  printf '%s' "$payload" | bridge_request --header 'Content-Type: application/json' \
    --data-binary @- --output "$download_temp" "${GH_BRIDGE_URL}/v1/github"
  # Publish only a completed download; linking also refuses concurrent overwrites.
  ln "$download_temp" "$download_file"
  printf '%s\n' "$download_file"
elif [ "$operation" = asset-upload ]; then
  bridge_request --header "Content-Type: $content_type" \
    --header "X-GitHub-Repository: $repository" \
    --header "X-GitHub-Asset-Name: $asset_name" \
    --data-binary "@$asset_file" "${GH_BRIDGE_URL}/v1/github/assets"
else
  printf '%s' "$payload" | bridge_request --header 'Content-Type: application/json' \
    --data-binary @- "${GH_BRIDGE_URL}/v1/github"
fi
