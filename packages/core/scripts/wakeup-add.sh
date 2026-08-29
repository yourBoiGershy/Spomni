#!/usr/bin/env bash
# wakeup-add.sh — the one sanctioned way any package appends a wake-up entry
# to a store's queue (packages/core/contracts/wakeup.md).
#
# Usage:
#   wakeup-add.sh <store-dir> --due YYYY-MM-DD --person <slug> [--person <slug> ...] \
#       --why "<one-liner>" --origin user-ask|signal|standing \
#       [--context "<text>"] [--draft "<text>"] [--source-signal <id>]
#
# Creates exactly one new file under <store-dir>/wakeups/, status: pending.
# Never modifies existing files. Creation only — no update/delete/fire modes
# (lifecycle transitions belong solely to packages/attention).

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> --due YYYY-MM-DD --person <slug> [--person <slug> ...] \\
    --why "<one-liner>" --origin user-ask|signal|standing \\
    [--context "<text>"] [--draft "<text>"] [--source-signal <id>]

Creates one new wakeups/<id>.md entry conforming to
packages/core/contracts/wakeup.md. Prints the created path on success.
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

{
  echo "---"
  echo "schema_version: 1.0.0"
  echo "id: ${ID}"
  echo "due: ${DUE}"
  echo "people: [${PEOPLE_YAML}]"
  echo "why: \"${WHY_ESCAPED}\""
  echo "status: pending"
  echo "origin: ${ORIGIN}"
  echo "source-signal: ${SOURCE_SIGNAL_VALUE}"
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
