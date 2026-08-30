#!/usr/bin/env bash
# heartbeat-stamp.sh — the one sanctioned way a scheduled routine records a
# completion stamp (packages/core/contracts/heartbeat.md).
#
# Usage:
#   heartbeat-stamp.sh <store-dir> <routine> --cadence-hours N [--ok|--fail] \
#       [--now <iso-datetime>]
#
# <routine> must match ^[a-z0-9-]+$. Writes
# <store-dir>/heartbeats/<routine>.json atomically (tmp+mv), overwriting any
# prior stamp for that routine. Default is --ok; --fail records a failed run
# (still a heartbeat — the schedule is alive). --now overrides the stamped_at
# timestamp (for tests); default is the current UTC time. Prints the written
# path on success. Scope: routines only — connector lanes use the sync
# scheduler's own state files, not this contract.
#
# bash 3.2 portable. No jq dependency for writing.

set -eu

usage() {
  echo "usage: heartbeat-stamp.sh <store-dir> <routine> --cadence-hours N [--ok|--fail] [--now <iso-datetime>]" >&2
  exit 2
}

if [ "$#" -lt 2 ]; then
  usage
fi

store_dir="$1"
routine="$2"
shift 2

cadence_hours=""
ok_flag="true"
now_override=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cadence-hours)
      [ "$#" -ge 2 ] || usage
      cadence_hours="$2"
      shift 2
      ;;
    --ok)
      ok_flag="true"
      shift
      ;;
    --fail)
      ok_flag="false"
      shift
      ;;
    --now)
      [ "$#" -ge 2 ] || usage
      now_override="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

case "$routine" in
  ""|*[!a-z0-9-]*) usage ;;
esac

if [ -z "$cadence_hours" ]; then
  usage
fi
case "$cadence_hours" in
  ''|*[!0-9]*) usage ;;
esac
if [ "$cadence_hours" -lt 1 ]; then
  usage
fi

if [ -z "$store_dir" ]; then
  usage
fi

if [ -n "$now_override" ]; then
  stamped_at="$now_override"
else
  stamped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

heartbeats_dir="${store_dir}/heartbeats"
mkdir -p "$heartbeats_dir"

out_file="${heartbeats_dir}/${routine}.json"
tmp_file="${out_file}.tmp.$$"

cat > "$tmp_file" <<EOF
{
  "schema_version": "1.0.0",
  "routine": "${routine}",
  "stamped_at": "${stamped_at}",
  "cadence_hours": ${cadence_hours},
  "ok": ${ok_flag}
}
EOF

mv -f "$tmp_file" "$out_file"

printf '%s\n' "$out_file"
