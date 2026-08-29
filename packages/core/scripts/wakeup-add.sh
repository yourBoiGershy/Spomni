#!/usr/bin/env bash
# wakeup-add.sh — the one sanctioned way any package appends a wake-up entry
# to a store's queue (packages/core/contracts/wakeup.md).
#
# Usage:
#   wakeup-add.sh <store-dir> --due YYYY-MM-DD --person <slug> [--person <slug> ...] \
#       --why "<one-liner>" --origin user-ask|signal|standing \
#       [--context "<text>"] [--draft "<text>"] [--source-signal <id>] \
#       [--kind event-proposal --event-title "<s>" --event-start <iso-datetime> \
#        --event-end <iso-datetime> --event-attendee <slug> [--event-attendee <slug> ...] \
#        [--event-location "<s>"]]
#
# Creates exactly one new file under <store-dir>/wakeups/, status: pending.
# Never modifies existing files. Creation only — no update/delete/fire modes
# (lifecycle transitions belong solely to packages/attention).
#
# --kind event-proposal (wakeup contract 1.2.0) requires --event-title,
# --event-start, --event-end, and at least one --event-attendee. The event
# flags are rejected when --kind is absent or --kind nudge. confirmed-on and
# created-event-id are never settable at creation — only by attention's
# lifecycle writes.

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> --due YYYY-MM-DD --person <slug> [--person <slug> ...] \\
    --why "<one-liner>" --origin user-ask|signal|standing \\
    [--context "<text>"] [--draft "<text>"] [--source-signal <id>] \\
    [--kind event-proposal --event-title "<s>" --event-start <iso-datetime> \\
     --event-end <iso-datetime> --event-attendee <slug> [--event-attendee <slug> ...] \\
     [--event-location "<s>"]]

Creates one new wakeups/<id>.md entry conforming to
packages/core/contracts/wakeup.md. Prints the created path on success.

With --kind event-proposal, the entry carries a proposed-event mapping
(wakeup contract 1.2.0): title/start/end/attendees are required, location is
optional. The event flags are rejected unless --kind event-proposal is set.
EOF
  exit 1
}

STORE_DIR=""
DUE=""
WHY=""
ORIGIN=""
CONTEXT=""
DRAFT=""
SOURCE_SIGNAL=""
PEOPLE=""
PEOPLE_COUNT=0
KIND=""
EVENT_TITLE=""
EVENT_START=""
EVENT_END=""
EVENT_LOCATION=""
EVENT_ATTENDEES=""
EVENT_ATTENDEES_COUNT=0

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
    --due)
      [ "$#" -ge 2 ] || usage
      DUE="$2"
      shift 2
      ;;
    --person)
      [ "$#" -ge 2 ] || usage
      if [ -z "${PEOPLE}" ]; then
        PEOPLE="$2"
      else
        PEOPLE="${PEOPLE}
$2"
      fi
      PEOPLE_COUNT=$((PEOPLE_COUNT + 1))
      shift 2
      ;;
    --why)
      [ "$#" -ge 2 ] || usage
      WHY="$2"
      shift 2
      ;;
    --origin)
      [ "$#" -ge 2 ] || usage
      ORIGIN="$2"
      shift 2
      ;;
    --context)
      [ "$#" -ge 2 ] || usage
      CONTEXT="$2"
      shift 2
      ;;
    --draft)
      [ "$#" -ge 2 ] || usage
      DRAFT="$2"
      shift 2
      ;;
    --source-signal)
      [ "$#" -ge 2 ] || usage
      SOURCE_SIGNAL="$2"
      shift 2
      ;;
    --kind)
      [ "$#" -ge 2 ] || usage
      KIND="$2"
      shift 2
      ;;
    --event-title)
      [ "$#" -ge 2 ] || usage
      EVENT_TITLE="$2"
      shift 2
      ;;
    --event-start)
      [ "$#" -ge 2 ] || usage
      EVENT_START="$2"
      shift 2
      ;;
    --event-end)
      [ "$#" -ge 2 ] || usage
      EVENT_END="$2"
      shift 2
      ;;
    --event-attendee)
      [ "$#" -ge 2 ] || usage
      if [ -z "${EVENT_ATTENDEES}" ]; then
        EVENT_ATTENDEES="$2"
      else
        EVENT_ATTENDEES="${EVENT_ATTENDEES}
$2"
      fi
      EVENT_ATTENDEES_COUNT=$((EVENT_ATTENDEES_COUNT + 1))
      shift 2
      ;;
    --event-location)
      [ "$#" -ge 2 ] || usage
      EVENT_LOCATION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# --- Validation ---

if [ -z "${DUE}" ]; then
  echo "Missing required --due" >&2
  usage
fi

# Validate DUE is a well-formed ISO 8601 date (YYYY-MM-DD) and a real date.
case "${DUE}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "Invalid --due: '${DUE}' (expected YYYY-MM-DD)" >&2
    usage
    ;;
esac

if ! date -j -f "%Y-%m-%d" "${DUE}" "+%Y-%m-%d" >/dev/null 2>&1; then
  # Fall back to GNU date syntax for portability across BSD/GNU environments.
  if ! date -d "${DUE}" "+%Y-%m-%d" >/dev/null 2>&1; then
    echo "Invalid --due: '${DUE}' is not a real calendar date" >&2
    usage
  fi
fi

if [ "${PEOPLE_COUNT}" -eq 0 ]; then
  echo "Missing required --person (at least one)" >&2
  usage
fi

if [ -z "${WHY}" ]; then
  echo "Missing required --why" >&2
  usage
fi

if [ -z "${ORIGIN}" ]; then
  echo "Missing required --origin" >&2
  usage
fi

case "${ORIGIN}" in
  user-ask|signal|standing) ;;
  *)
    echo "Invalid --origin: '${ORIGIN}' (expected one of: user-ask, signal, standing)" >&2
    usage
    ;;
esac

if [ "${ORIGIN}" = "signal" ] && [ -z "${SOURCE_SIGNAL}" ]; then
  echo "--source-signal is required (non-null) when --origin is 'signal'" >&2
  usage
fi

# --- kind / event-proposal validation ---

if [ -n "${KIND}" ]; then
  case "${KIND}" in
    nudge|event-proposal) ;;
    *)
      echo "Invalid --kind: '${KIND}' (expected one of: nudge, event-proposal)" >&2
      usage
      ;;
  esac
fi

if [ "${KIND}" = "event-proposal" ]; then
  if [ -z "${EVENT_TITLE}" ]; then
    echo "Missing required --event-title (required when --kind event-proposal)" >&2
    usage
  fi
  if [ -z "${EVENT_START}" ]; then
    echo "Missing required --event-start (required when --kind event-proposal)" >&2
    usage
  fi
  if [ -z "${EVENT_END}" ]; then
    echo "Missing required --event-end (required when --kind event-proposal)" >&2
    usage
  fi
  if [ "${EVENT_ATTENDEES_COUNT}" -eq 0 ]; then
    echo "Missing required --event-attendee (at least one, required when --kind event-proposal)" >&2
    usage
  fi
else
  if [ -n "${EVENT_TITLE}" ] || [ -n "${EVENT_START}" ] || [ -n "${EVENT_END}" ] \
    || [ -n "${EVENT_LOCATION}" ] || [ "${EVENT_ATTENDEES_COUNT}" -gt 0 ]; then
    echo "Event flags (--event-title/--event-start/--event-end/--event-attendee/--event-location) require --kind event-proposal" >&2
    usage
  fi
fi

if [ ! -d "${STORE_DIR}" ]; then
  echo "Store directory does not exist: '${STORE_DIR}'" >&2
  usage
fi

WAKEUPS_DIR="${STORE_DIR}/wakeups"
mkdir -p "${WAKEUPS_DIR}"

# --- Build people list (YAML array of [[slug]] links) ---

PRIMARY_SLUG="$(printf '%s\n' "${PEOPLE}" | head -n 1)"

PEOPLE_YAML=""
OLD_IFS="${IFS}"
IFS='
'
for slug in ${PEOPLE}; do
  if [ -z "${PEOPLE_YAML}" ]; then
    PEOPLE_YAML="\"[[${slug}]]\""
  else
    PEOPLE_YAML="${PEOPLE_YAML}, \"[[${slug}]]\""
  fi
done
IFS="${OLD_IFS}"

# --- Build event-attendees list (YAML array of [[slug]] links), if any ---

EVENT_ATTENDEES_YAML=""
if [ "${EVENT_ATTENDEES_COUNT}" -gt 0 ]; then
  OLD_IFS="${IFS}"
  IFS='
'
  for slug in ${EVENT_ATTENDEES}; do
    if [ -z "${EVENT_ATTENDEES_YAML}" ]; then
      EVENT_ATTENDEES_YAML="\"[[${slug}]]\""
    else
      EVENT_ATTENDEES_YAML="${EVENT_ATTENDEES_YAML}, \"[[${slug}]]\""
    fi
  done
  IFS="${OLD_IFS}"
fi

# --- Determine unique id / filename per contract's recommended form:
#     <due-date>-<primary-person-slug>[--<n>]

BASE_ID="${DUE}-${PRIMARY_SLUG}"
ID="${BASE_ID}"
SUFFIX=2
while [ -e "${WAKEUPS_DIR}/${ID}.md" ]; do
  ID="${BASE_ID}--${SUFFIX}"
  SUFFIX=$((SUFFIX + 1))
done

TARGET_FILE="${WAKEUPS_DIR}/${ID}.md"

SOURCE_SIGNAL_VALUE="null"
if [ -n "${SOURCE_SIGNAL}" ]; then
  SOURCE_SIGNAL_VALUE="${SOURCE_SIGNAL}"
fi

# --- Escape double quotes in scalar string fields for YAML safety ---

escape_yaml() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

WHY_ESCAPED="$(escape_yaml "${WHY}")"

SCHEMA_VERSION="1.0.0"
if [ "${KIND}" = "event-proposal" ]; then
  SCHEMA_VERSION="1.2.0"
fi

{
  echo "---"
  echo "schema_version: ${SCHEMA_VERSION}"
  echo "id: ${ID}"
  echo "due: ${DUE}"
  echo "people: [${PEOPLE_YAML}]"
  echo "why: \"${WHY_ESCAPED}\""
  echo "status: pending"
  echo "origin: ${ORIGIN}"
  echo "source-signal: ${SOURCE_SIGNAL_VALUE}"
  if [ "${KIND}" = "event-proposal" ]; then
    echo "kind: event-proposal"
    echo "proposed-event:"
    echo "  title: ${EVENT_TITLE}"
    echo "  start: ${EVENT_START}"
    echo "  end: ${EVENT_END}"
    echo "  attendees: [${EVENT_ATTENDEES_YAML}]"
    if [ -n "${EVENT_LOCATION}" ]; then
      echo "  location: ${EVENT_LOCATION}"
    else
      echo "  location:"
    fi
    echo "confirmed-on:"
    echo "created-event-id:"
  fi
  echo "---"
  echo ""
  echo "## Context"
  echo ""
  if [ -n "${CONTEXT}" ]; then
    printf '%s\n' "${CONTEXT}"
  fi
  if [ -n "${DRAFT}" ]; then
    echo ""
    echo "## Draft"
    echo ""
    printf '%s\n' "${DRAFT}"
  fi
} > "${TARGET_FILE}"

echo "${TARGET_FILE}"
