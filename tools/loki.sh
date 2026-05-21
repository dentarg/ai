#!/usr/bin/env bash
#
# Download Loki logs in resumable chunks via logcli.
#
# Expects LOKI_ADDR (and any LOKI_USERNAME / LOKI_PASSWORD / LOKI_BEARER_TOKEN /
# LOKI_ORG_ID etc.) to be set in the environment. With --stack NAME, the script
# instead reads NAME_LOKI_* vars (e.g. --stack app reads APP_LOKI_ADDR,
# APP_LOKI_USERNAME, ...) and exports them as LOKI_* for logcli.
#
# Loki has a 30-day per-query limit, and even single 30-day queries time out.
# This script splits the requested range into outer chunks (default 1 day) and
# inside each chunk uses logcli's own parallel-duration / part-file machinery,
# which is also resumable across runs.
#
# Re-running with the same --out-dir resumes where the previous run stopped:
# already-finished chunks are skipped, partially-downloaded inner parts are
# resumed by logcli itself.

set -euo pipefail

SCRIPT=${0##*/}
CHUNK=1d
PARALLEL=15m
WORKERS=4
QUERY=
SERVICE=
RANGE=
FROM=
TO=
OUT_DIR=
STACK=

usage() {
  cat <<EOF
Usage:
  $SCRIPT --service NAME --range DUR        [options]
  $SCRIPT --service NAME --from TS [--to TS] [options]

Range (one of):
  --range DUR        Lookback duration (e.g. 60d, 2d, 12h, 30m).
  --from RFC3339     Absolute start (e.g. 2026-03-21T00:00:00Z).
  --to   RFC3339     Absolute end (default: now).

Options:
  --service NAME     Loki service_name label value (e.g. cloudamqp-api).
  --stack NAME       Select a Loki endpoint by env-var prefix. With --stack app,
                     each APP_LOKI_* var is exported as LOKI_* for logcli
                     (APP_LOKI_ADDR → LOKI_ADDR, etc.). If omitted, the
                     existing LOKI_* vars are used as-is.
  --chunk DUR        Outer chunk size, must be < 30d (default: $CHUNK).
  --parallel DUR     logcli --parallel-duration inside each chunk (default: $PARALLEL).
  --workers N        logcli --parallel-max-workers inside each chunk (default: $WORKERS).
  --out-dir DIR      Output directory. Default: ./loki-<service>.
                     Re-running with the same dir resumes.
  --query LOGQL      Override the default LogQL ({service_name="<service>"}).
  -h, --help

Output layout under --out-dir:
  chunk_<from>_<to>.jsonl    one merged JSONL file per outer chunk
  parts/                     logcli part files (intermediate, kept for resume)
  fetch.log                  this run's progress / stderr
EOF
}

die() { echo "$SCRIPT: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --service)   SERVICE=$2; shift 2;;
    --range)     RANGE=$2;   shift 2;;
    --from)      FROM=$2;    shift 2;;
    --to)        TO=$2;      shift 2;;
    --chunk)     CHUNK=$2;   shift 2;;
    --parallel)  PARALLEL=$2; shift 2;;
    --workers)   WORKERS=$2; shift 2;;
    --out-dir)   OUT_DIR=$2; shift 2;;
    --query)     QUERY=$2;   shift 2;;
    --stack)     STACK=$2;   shift 2;;
    -h|--help)   usage; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[ -n "$SERVICE" ]                || die "missing --service"
[ -n "$RANGE" ] || [ -n "$FROM" ] || die "need --range or --from"
[ -n "$RANGE" ] && [ -n "$FROM" ] && die "use --range OR --from/--to, not both"
command -v logcli >/dev/null      || die "logcli not on PATH"
command -v python3 >/dev/null     || die "python3 not on PATH (needed for date math)"

if [ -n "$STACK" ]; then
  prefix="$(echo "$STACK" | tr '[:lower:]' '[:upper:]')_LOKI_"
  copied=0
  for name in $(compgen -e); do
    case "$name" in
      "${prefix}"*)
        export "LOKI_${name#"${prefix}"}=${!name}"
        copied=$((copied + 1))
        ;;
    esac
  done
  [ "$copied" -gt 0 ] || die "no env vars found with prefix '${prefix}' for --stack=$STACK"
fi
[ -n "${LOKI_ADDR:-}" ] || die "LOKI_ADDR not set${STACK:+ (looked for ${prefix}ADDR)}"

dur_to_seconds() {
  python3 -c '
import re, sys
m = re.fullmatch(r"(\d+)([smhd])", sys.argv[1])
if not m: sys.exit(f"bad duration: {sys.argv[1]!r} (use e.g. 60d, 12h, 30m)")
print(int(m.group(1)) * {"s":1,"m":60,"h":3600,"d":86400}[m.group(2)])
' "$1"
}

rfc3339_to_epoch() {
  python3 -c '
import sys, datetime
s = sys.argv[1].rstrip("Z")
dt = datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
' "$1"
}

epoch_to_rfc3339() {
  python3 -c '
import sys, datetime
ts = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$1"
}

NOW=$(date -u +%s)

if [ -n "$RANGE" ]; then
  FROM_EPOCH=$(( NOW - $(dur_to_seconds "$RANGE") ))
  TO_EPOCH=$NOW
else
  FROM_EPOCH=$(rfc3339_to_epoch "$FROM")
  if [ -n "$TO" ]; then TO_EPOCH=$(rfc3339_to_epoch "$TO"); else TO_EPOCH=$NOW; fi
fi
[ "$FROM_EPOCH" -lt "$TO_EPOCH" ] || die "from is not before to"

CHUNK_S=$(dur_to_seconds "$CHUNK")
[ "$CHUNK_S" -gt 0 ] && [ "$CHUNK_S" -lt $((30 * 86400)) ] \
  || die "--chunk must be > 0 and < 30d"

[ -n "$OUT_DIR" ] || OUT_DIR="./loki-$SERVICE"
mkdir -p "$OUT_DIR/parts"
LOG="$OUT_DIR/fetch.log"

[ -n "$QUERY" ] || QUERY="{service_name=\"$SERVICE\"}"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
log "service:  $SERVICE"
log "from:     $(epoch_to_rfc3339 "$FROM_EPOCH")"
log "to:       $(epoch_to_rfc3339 "$TO_EPOCH")"
log "chunk:    $CHUNK (inner parallel-duration=$PARALLEL workers=$WORKERS)"
log "query:    $QUERY"
log "out-dir:  $OUT_DIR"

total_chunks=$(( (TO_EPOCH - FROM_EPOCH + CHUNK_S - 1) / CHUNK_S ))
log "chunks:   $total_chunks"

cur=$FROM_EPOCH
i=0
while [ "$cur" -lt "$TO_EPOCH" ]; do
  nxt=$(( cur + CHUNK_S ))
  [ "$nxt" -gt "$TO_EPOCH" ] && nxt=$TO_EPOCH
  i=$(( i + 1 ))

  cur_iso=$(epoch_to_rfc3339 "$cur")
  nxt_iso=$(epoch_to_rfc3339 "$nxt")
  tag="$(echo "$cur_iso" | tr -d ':-' | tr -d Z)_$(echo "$nxt_iso" | tr -d ':-' | tr -d Z)"
  out_file="$OUT_DIR/chunk_${tag}.jsonl"

  if [ -f "$out_file" ]; then
    log "[$i/$total_chunks] $cur_iso → $nxt_iso  already done, skipping"
    cur=$nxt
    continue
  fi

  log "[$i/$total_chunks] $cur_iso → $nxt_iso  fetching"
  if logcli query \
        --quiet \
        --timezone=UTC \
        --from="$cur_iso" \
        --to="$nxt_iso" \
        --output=jsonl \
        --forward \
        --limit=0 \
        --batch=5000 \
        --parallel-duration="$PARALLEL" \
        --parallel-max-workers="$WORKERS" \
        --part-path-prefix="$OUT_DIR/parts/${tag}" \
        --merge-parts \
        --keep-parts \
        "$QUERY" \
        > "${out_file}.tmp" 2>>"$LOG"; then
    mv "${out_file}.tmp" "$out_file"
    lines=$(wc -l <"$out_file" | tr -d ' ')
    log "[$i/$total_chunks] done, $lines lines → $out_file"
  else
    rc=$?
    log "[$i/$total_chunks] FAILED rc=$rc, leaving ${out_file}.tmp for inspection"
    exit "$rc"
  fi

  cur=$nxt
done

log "all done. $i chunks in $OUT_DIR"
