#!/usr/bin/env bash
# staleness.sh — the deterministic staleness check for the `sweep` skill.
# A dead schedule announces itself, once.
#
# Reads two read-only sources and creates at most one pending wake-up per
# stale subject (never a duplicate while one is already pending or
# fired-unresolved):
#   1. Routine heartbeats — <store>/heartbeats/<routine>.json
#      (packages/core/contracts/heartbeat.md 1.0.0). Stale when
#      now - stamped_at > 2 * cadence_hours. Missing dir/file = nothing to
#      check (a routine that never ran is not yet an alarm).
#   2. Connector lanes — <sync-data-dir>/connectors/sync-scheduler/lanes.tsv
#      (lane<TAB>interval_seconds<TAB>enabled<TAB>command; only enabled ==
#      true lanes count) and .../state/<lane>.tsv (last_start<TAB>last_end
#      <TAB>last_exit). Stale when now - last_end > 2 * interval_seconds
#      (falls back to last_start if last_end is empty). A lane with no
#      state file has never run -> not stale. Missing lanes.tsv -> skip
#      lane checks silently.
#
# Usage:
#   staleness.sh <store-dir> [--sync-data-dir <dir>] [--now <iso-utc>] [--dry-run]
#
# --sync-data-dir defaults to <repo-root>/data (repo root three levels up
# from this script). --now overrides current time (tests). --dry-run prints
# what would be created without creating anything.
#
# Dedup: before creating, scans <store>/wakeups/*.md frontmatter; if any
# file has source-signal: staleness:<name> AND status: pending, or
# status: fired with acted-on absent/null/false, creation is skipped.
# Wake-ups are created solely via packages/core/scripts/wakeup-add.sh, one
# call per stale subject, with --person self (a reserved slug — no
# people/self.md required).
#
# Prints one line per subject checked:
#   staleness: <name> ok|stale|already-pending|never-run (<detail>)
#
# Exit 0 always, unless usage error (2) or jq is missing (2).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
WAKEUP_ADD="${REPO_ROOT}/packages/core/scripts/wakeup-add.sh"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> [--sync-data-dir <dir>] [--now <iso-utc>] [--dry-run]

Checks routine heartbeats (<store-dir>/heartbeats/*.json) and connector-lane
scheduler state (<sync-data-dir>/connectors/sync-scheduler/) for silence
past 2x their cadence, creating exactly one pending wake-up per stale
subject (skipping if one is already pending or fired-unresolved).
EOF
  exit 2
}

STORE_DIR=""
SYNC_DATA_DIR=""
NOW=""
DRY_RUN=0

if [ "$#" -lt 1 ]; then
  usage
fi

STORE_DIR="$1"
shift

if [ -z "${STORE_DIR}" ]; then
  usage
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sync-data-dir)
      [ "$#" -ge 2 ] || usage
      SYNC_DATA_DIR="$2"
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || usage
      NOW="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ -z "${SYNC_DATA_DIR}" ]; then
  SYNC_DATA_DIR="${REPO_ROOT}/data"
fi

if [ -z "${NOW}" ]; then
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "${SCRIPT_NAME}: jq is required but not found on PATH" >&2
  exit 2
fi

if [ ! -d "${STORE_DIR}" ]; then
  echo "${SCRIPT_NAME}: store directory does not exist: '${STORE_DIR}'" >&2
  usage
fi

# --- Portable ISO-8601 -> epoch seconds --------------------------------

if date -u -j >/dev/null 2>&1; then
  DATE_FLAVOR="bsd"
else
  DATE_FLAVOR="gnu"
fi

iso_to_epoch() {
  raw="$1"
  # Strip fractional seconds and normalize +00:00 -> Z.
  clean="$(printf '%s' "${raw}" | sed -E 's/\.[0-9]+Z$/Z/; s/\+00:00$/Z/')"
  case "${clean}" in
    *Z) ;;
    *) clean="${clean}Z" ;;
  esac
  if [ "${DATE_FLAVOR}" = "bsd" ]; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${clean}" +%s 2>/dev/null
  else
    date -u -d "${clean}" +%s 2>/dev/null
  fi
}

NOW_EPOCH="$(iso_to_epoch "${NOW}")"
if [ -z "${NOW_EPOCH}" ]; then
  echo "${SCRIPT_NAME}: could not parse --now '${NOW}' as ISO-8601 UTC" >&2
  usage
fi

TODAY="$(printf '%s' "${NOW}" | cut -c1-10)"

# --- Dedup: is a staleness wake-up already pending/fired-unresolved? ----

# already_pending <name> — prints the matching file path if a wakeups/*.md
# frontmatter has source-signal: staleness:<name> AND (status: pending, or
# status: fired with acted-on absent/null/false). Empty output = not found.
already_pending() {
  name="$1"
  wakeups_dir="${STORE_DIR}/wakeups"
  [ -d "${wakeups_dir}" ] || return 0

  for f in "${wakeups_dir}"/*.md; do
    [ -e "${f}" ] || continue
    src="$(get_field_file "${f}" "source-signal")"
    [ "${src}" = "staleness:${name}" ] || continue
    status="$(get_field_file "${f}" "status")"
    if [ "${status}" = "pending" ]; then
      printf '%s\n' "${f}"
      return 0
    fi
    if [ "${status}" = "fired" ]; then
      acted="$(get_field_file "${f}" "acted-on")"
      case "${acted}" in
        ""|"null"|"false")
          printf '%s\n' "${f}"
          return 0
          ;;
      esac
    fi
  done
  return 0
}

# get_field_file <file> <field> — echo the frontmatter scalar value (empty
# string if absent). Frontmatter-only, first "---"/"---" delimited block.
get_field_file() {
  file="$1"
  field="$2"
  awk -v field="${field}" '
    BEGIN { infm = 0; fmlines = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; next }
        if (fmlines == 2) { infm = 0; exit }
      }
      if (!infm) next
      bare = field ":"
      prefix = field ": "
      if ($0 == bare) {
        print ""
        exit
      }
      if (index($0, prefix) == 1) {
        val = $0
        sub("^" prefix, "", val)
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        gsub(/^"|"$/, "", val)
        print val
        exit
      }
    }
  ' "${file}"
}

# create_staleness_wakeup <name> <why> — the one sanctioned creation call,
# gated by already_pending; respects --dry-run.
create_staleness_wakeup() {
  name="$1"
  why="$2"

  existing="$(already_pending "${name}")"
  if [ -n "${existing}" ]; then
    echo "staleness: ${name} already-pending (${existing})"
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "staleness: ${name} stale (would create: ${why})"
    return 0
  fi

  created="$(bash "${WAKEUP_ADD}" "${STORE_DIR}" --due "${TODAY}" \
    --person self --why "${why}" --origin standing \
    --source-signal "staleness:${name}" --signal-type staleness)"
  echo "staleness: ${name} stale (${created})"
}

# --- 1. Routine heartbeats ----------------------------------------------

HEARTBEATS_DIR="${STORE_DIR}/heartbeats"
if [ -d "${HEARTBEATS_DIR}" ]; then
  for hb in "${HEARTBEATS_DIR}"/*.json; do
    [ -e "${hb}" ] || continue
    routine="$(jq -r '.routine' "${hb}")"
    stamped_at="$(jq -r '.stamped_at' "${hb}")"
    cadence_hours="$(jq -r '.cadence_hours' "${hb}")"

    if [ -z "${routine}" ] || [ "${routine}" = "null" ]; then
      routine="$(basename "${hb}" .json)"
    fi

    stamped_epoch="$(iso_to_epoch "${stamped_at}")"
    if [ -z "${stamped_epoch}" ]; then
      echo "staleness: ${routine} ok (unparseable stamped_at, skipped)"
      continue
    fi

    threshold=$((cadence_hours * 2 * 3600))
    age=$((NOW_EPOCH - stamped_epoch))

    if [ "${age}" -gt "${threshold}" ]; then
      create_staleness_wakeup "${routine}" \
        "routine ${routine} has not run since ${stamped_at} (cadence ${cadence_hours}h) — check the schedule"
    else
      echo "staleness: ${routine} ok (last stamped ${stamped_at})"
    fi
  done
fi

# --- 2. Connector lanes --------------------------------------------------

LANES_TSV="${SYNC_DATA_DIR}/connectors/sync-scheduler/lanes.tsv"
if [ -f "${LANES_TSV}" ]; then
  while IFS="$(printf '\t')" read -r lane interval enabled command || [ -n "${lane}" ]; do
    case "${lane}" in
      ""|"#"*) continue ;;
    esac
    [ "${enabled}" = "true" ] || continue

    state_file="${SYNC_DATA_DIR}/connectors/sync-scheduler/state/${lane}.tsv"
    if [ ! -f "${state_file}" ]; then
      echo "staleness: ${lane} never-run (no state file)"
      continue
    fi

    IFS="$(printf '\t')" read -r last_start last_end last_exit < "${state_file}" || true

    ref_iso="${last_end}"
    if [ -z "${ref_iso}" ]; then
      ref_iso="${last_start}"
    fi
    if [ -z "${ref_iso}" ]; then
      echo "staleness: ${lane} never-run (empty state)"
      continue
    fi

    ref_epoch="$(iso_to_epoch "${ref_iso}")"
    if [ -z "${ref_epoch}" ]; then
      echo "staleness: ${lane} ok (unparseable state timestamp, skipped)"
      continue
    fi

    threshold=$((interval * 2))
    age=$((NOW_EPOCH - ref_epoch))

    if [ "${age}" -gt "${threshold}" ]; then
      create_staleness_wakeup "${lane}" \
        "lane ${lane} has not run since ${ref_iso} (cadence ${interval}s) — check the schedule"
    else
      echo "staleness: ${lane} ok (last ran ${ref_iso})"
    fi
  done < "${LANES_TSV}"
fi

exit 0
