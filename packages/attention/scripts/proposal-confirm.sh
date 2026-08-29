#!/bin/bash
# proposal-confirm.sh — interim confirm/decline lifecycle writer for
# `kind: event-proposal` wake-ups (packages/core/contracts/wakeup.md 1.2.0).
#
# INTERIM: this script is retired once plan 06's `wakeup-queue.sh` lands and
# absorbs its two ops (docs/plans/2026-08-29-21-calendar-intelligence.md,
# "Amendments to unbuilt plans" — Plan 06 note). Until then it is the sole
# writer of the confirm/decline lifecycle fields on event-proposal entries,
# per wakeup.md's writer table ("Confirming or declining an event-proposal
# entry is a lifecycle write like any other and stays attention's alone.")
#
# Usage:
#   proposal-confirm.sh <store-dir> confirm <wakeup-id> --event-id <id>
#   proposal-confirm.sh <store-dir> decline <wakeup-id> --reason <reason>
#
# confirm:
#   - target must be status pending/fired (not already dismissed) and not
#     already confirmed (confirmed-on must be null).
#   - writes confirmed-on (today, ISO date), created-event-id (the
#     --event-id value), and acted-on: true. Does not touch status: the
#     wakeup status enum (pending/fired/snoozed/dismissed) has no
#     "confirmed" member — status transitions remain the sweep's alone.
#   - invariant enforced structurally: this is the ONLY path that writes
#     created-event-id, and it always writes confirmed-on in the same
#     operation (wakeup.md: "created-event-id non-null requires
#     confirmed-on non-null AND kind: event-proposal").
#
# decline:
#   - target must not already be dismissed or confirmed.
#   - writes status: dismissed and dismiss-reason: <reason> — the standard
#     dismiss mechanics (wakeup.md), unchanged for event-proposal entries.
#     No new artifact, no other field touched (silent-decline doctrine:
#     the dismissed file is itself the record).
#
# Both ops only ever apply to kind: event-proposal entries — kind: nudge (or
# missing kind, which reads as nudge) is refused. Single-writer: this script
# never creates wakeup entries (that is core's wakeup-add.sh alone).
#
# In-place edits touch only the specific frontmatter field lines being
# changed; every other line (including the two `---` fences and both prose
# sections) is passed through byte-identical.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage:
  ${SCRIPT_NAME} <store-dir> confirm <wakeup-id> --event-id <connector-event-id>
  ${SCRIPT_NAME} <store-dir> decline <wakeup-id> --reason <not-now|not-this-person|not-this-signal-type|already-handled>

Writes the confirm/decline lifecycle fields on a kind: event-proposal
wake-up per packages/core/contracts/wakeup.md 1.2.0. Refuses non-proposal
kinds and already-confirmed/already-dismissed targets.
EOF
  exit 1
}

if [ "$#" -lt 3 ]; then
  usage
fi

STORE_DIR="$1"
ACTION="$2"
WAKEUP_ID="$3"
shift 3

if [ "${ACTION}" != "confirm" ] && [ "${ACTION}" != "decline" ]; then
  echo "${SCRIPT_NAME}: unknown action '${ACTION}' (expected confirm or decline)" >&2
  usage
fi

if [ ! -d "${STORE_DIR}" ]; then
  echo "${SCRIPT_NAME}: store directory does not exist: '${STORE_DIR}'" >&2
  exit 1
fi

EVENT_ID=""
REASON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event-id)
      [ "$#" -ge 2 ] || usage
      EVENT_ID="$2"
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || usage
      REASON="$2"
      shift 2
      ;;
    *)
      echo "${SCRIPT_NAME}: unknown argument: $1" >&2
      usage
      ;;
  esac
done

WAKEUP_FILE="${STORE_DIR}/wakeups/${WAKEUP_ID}.md"

if [ ! -f "${WAKEUP_FILE}" ]; then
  echo "${SCRIPT_NAME}: no such wake-up: '${WAKEUP_FILE}'" >&2
  exit 1
fi

# --- Read a single frontmatter field (between the two `---` fences) --------
#
# Returns the raw value after "field: " (surrounding double-quotes stripped),
# or empty string if absent/null. Mirrors calibrate.sh's extraction style.

get_field() {
  field="$1"
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
        gsub(/^"|"$/, "", val)
        print val
        exit
      }
    }
  ' "${WAKEUP_FILE}"
}

# --- Rewrite a single frontmatter field line in place -----------------------
#
# Replaces the first line matching "^<field>: " within the frontmatter block
# with "<field>: <new_value>"; every other line (including the two `---`
# fences, other frontmatter fields, and both body sections) passes through
# unchanged. Refuses if the field is not found (caller error, not a normal
# path here — every field this script writes already exists per the 1.2.0
# schema, just possibly empty).

set_field() {
  field="$1"
  new_value="$2"
  tmp_file="$(mktemp)"
  awk -v field="${field}" -v new_value="${new_value}" '
    BEGIN { infm = 0; fmlines = 0; done = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; print; next }
        if (fmlines == 2) { infm = 0; print; next }
      }
      if (infm && !done) {
        bare = field ":"
        prefix = field ": "
        if ($0 == bare || index($0, prefix) == 1) {
          print field ": " new_value
          done = 1
          next
        }
      }
      print
    }
  ' "${WAKEUP_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${WAKEUP_FILE}"
}

KIND="$(get_field kind)"
if [ -z "${KIND}" ]; then
  KIND="nudge"
fi

if [ "${KIND}" != "event-proposal" ]; then
  echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is kind: ${KIND}, not event-proposal — refusing" >&2
  exit 1
fi

STATUS="$(get_field status)"
CONFIRMED_ON="$(get_field confirmed-on)"

if [ "${STATUS}" = "dismissed" ]; then
  echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is already dismissed — refusing" >&2
  exit 1
fi

if [ -n "${CONFIRMED_ON}" ]; then
  echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is already confirmed (confirmed-on: ${CONFIRMED_ON}) — refusing" >&2
  exit 1
fi

if [ "${ACTION}" = "confirm" ]; then
  if [ -z "${EVENT_ID}" ]; then
    echo "${SCRIPT_NAME}: confirm requires --event-id" >&2
    usage
  fi

  TODAY="$(date -u +%Y-%m-%d)"

  set_field "confirmed-on" "${TODAY}"
  set_field "created-event-id" "${EVENT_ID}"
  set_field "acted-on" "true"

  echo "confirmed ${WAKEUP_ID} -> created-event-id: ${EVENT_ID} (confirmed-on: ${TODAY})"
else
  case "${REASON}" in
    not-now|not-this-person|not-this-signal-type|already-handled) ;;
    "")
      echo "${SCRIPT_NAME}: decline requires --reason" >&2
      usage
      ;;
    *)
      echo "${SCRIPT_NAME}: invalid --reason '${REASON}' (expected not-now|not-this-person|not-this-signal-type|already-handled)" >&2
      exit 1
      ;;
  esac

  set_field "status" "dismissed"
  set_field "dismiss-reason" "${REASON}"

  echo "declined ${WAKEUP_ID} -> dismiss-reason: ${REASON}"
fi
