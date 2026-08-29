#!/bin/bash
# normalize-capture.sh — shared normalizer every input lane pipes through.
#
# Usage:
#   normalize-capture.sh <store-dir> --source <name> --type <type>
#       [--captured-at <ISO8601Z, default now>]
#       [--occurred-at <ISO8601Z>]
#       [--id <id, default <captured_at-compact>-<source>-<4-hex-rand>>]
#       [--hint <string>]...
#       [--file <path> | body on stdin]
#
# Takes raw captured text plus envelope metadata and writes a valid
# capture-event file into <store-dir>/inbox/ per
# packages/core/contracts/capture-event.md. Anything invalid lands in
# <store-dir>/inbox/quarantine/ with a reason file.
#
# Envelope-only: the body is written byte-for-byte verbatim, never trimmed,
# reformatted, or redacted. Empty body is VALID (capture is lossy-tolerant).
#
# Exit 0 only on a written inbox event (prints the inbox path to stdout).
# Exit 1 on quarantine (prints the quarantine path to stderr).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

STORE_DIR="${1:-}"
if [ -z "$STORE_DIR" ]; then
  echo "normalize-capture.sh: <store-dir> is required" >&2
  exit 1
fi
shift

SOURCE=""
TYPE=""
CAPTURED_AT=""
OCCURRED_AT=""
ID=""
FILE=""
# Hints accumulated as newline-separated entries (bash-3.2 has no arrays
# of the modern kind we'd want to rely on across all builtins, but plain
# indexed arrays are fine in bash 3.2 — avoid associative arrays only).
HINTS_FILE_TMP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --type)
      TYPE="${2:-}"
      shift 2
      ;;
    --captured-at)
      CAPTURED_AT="${2:-}"
      shift 2
      ;;
    --occurred-at)
      OCCURRED_AT="${2:-}"
      shift 2
      ;;
    --id)
      ID="${2:-}"
      shift 2
      ;;
    --hint)
      if [ -z "$HINTS_FILE_TMP" ]; then
        HINTS_FILE_TMP="$(mktemp)"
      fi
      printf '%s\n' "${2:-}" >> "$HINTS_FILE_TMP"
      shift 2
      ;;
    --file)
      FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "normalize-capture.sh: unrecognized argument: $1" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  [ -n "$HINTS_FILE_TMP" ] && rm -f "$HINTS_FILE_TMP"
}
trap cleanup EXIT

INBOX_DIR="${STORE_DIR}/inbox"
QUARANTINE_DIR="${INBOX_DIR}/quarantine"
mkdir -p "$INBOX_DIR" "$QUARANTINE_DIR"

# ---------------------------------------------------------------------------
# Read the body verbatim (byte-for-byte), from --file or stdin.
# ---------------------------------------------------------------------------

BODY_TMP="$(mktemp)"
trap 'rm -f "$HINTS_FILE_TMP" "$BODY_TMP"' EXIT

if [ -n "$FILE" ]; then
  if [ ! -e "$FILE" ]; then
    echo "normalize-capture.sh: --file not found: $FILE" >&2
    exit 1
  fi
  cat "$FILE" > "$BODY_TMP"
else
  cat > "$BODY_TMP"
fi

# ---------------------------------------------------------------------------
# Defaults: captured_at, id.
# ---------------------------------------------------------------------------

if [ -z "$CAPTURED_AT" ]; then
  CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# Compact form of captured_at for the default id, e.g. 20260829T143200Z.
captured_at_compact() {
  printf '%s' "$1" | sed -E 's/[-:]//g'
}

rand_hex4() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 2
  else
    printf '%04x' "$((RANDOM % 65536))"
  fi
}

if [ -z "$ID" ]; then
  ID="$(captured_at_compact "$CAPTURED_AT")-${SOURCE}-$(rand_hex4)"
fi

# ---------------------------------------------------------------------------
# Validation.
# ---------------------------------------------------------------------------

VALID=1
REASON=""

add_reason() {
  if [ -n "$REASON" ]; then
    REASON="${REASON}
$1"
  else
    REASON="$1"
  fi
  VALID=0
}

if [ -z "$SOURCE" ]; then
  add_reason "source is required and must be non-empty"
fi

case "$TYPE" in
  voice-note|linkedin-notification|event-confirmation|transcript|other|email|calendar-event|profile-snapshot|contact-record|post)
    ;;
  *)
    add_reason "invalid type: '${TYPE}' (expected one of: voice-note, linkedin-notification, event-confirmation, transcript, other, email, calendar-event, profile-snapshot, contact-record, post)"
    ;;
esac

if ! printf '%s' "$CAPTURED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  add_reason "invalid captured_at: '${CAPTURED_AT}' (expected ISO 8601 YYYY-MM-DDTHH:MM:SSZ)"
fi

if [ -n "$OCCURRED_AT" ] && ! printf '%s' "$OCCURRED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  add_reason "invalid occurred_at: '${OCCURRED_AT}' (expected ISO 8601 YYYY-MM-DDTHH:MM:SSZ)"
fi

if [ -e "${INBOX_DIR}/${ID}.md" ]; then
  add_reason "id already exists in inbox/: '${ID}' (never overwrite)"
fi

# ---------------------------------------------------------------------------
# Write.
# ---------------------------------------------------------------------------

write_frontmatter() {
  # $1 = destination file
  dest="$1"
  {
    printf '%s\n' "---"
    printf 'schema_version: 1.1.0\n'
    printf 'id: %s\n' "$ID"
    printf 'source: %s\n' "$SOURCE"
    printf 'captured_at: %s\n' "$CAPTURED_AT"
    if [ -n "$OCCURRED_AT" ]; then
      printf 'occurred_at: %s\n' "$OCCURRED_AT"
    fi
    printf 'type: %s\n' "$TYPE"
    if [ -n "$HINTS_FILE_TMP" ] && [ -s "$HINTS_FILE_TMP" ]; then
      printf 'participant-hints:\n'
      while IFS= read -r hint; do
        printf '  - "%s"\n' "$hint"
      done < "$HINTS_FILE_TMP"
    else
      printf 'participant-hints: []\n'
    fi
    printf '%s\n' "---"
  } > "$dest"
}

if [ "$VALID" -eq 1 ]; then
  DEST="${INBOX_DIR}/${ID}.md"
  write_frontmatter "$DEST"
  cat "$BODY_TMP" >> "$DEST"
  printf '%s\n' "$DEST"
  exit 0
else
  # Never overwrite an existing quarantine entry either — pick a stable
  # stem from id (or timestamp if id itself is the problem/duplicate).
  STEM="$ID"
  if [ -e "${QUARANTINE_DIR}/${STEM}.md" ]; then
    STEM="$(date -u +%Y%m%dT%H%M%SZ)-$(rand_hex4)"
  fi
  Q_DEST="${QUARANTINE_DIR}/${STEM}.md"
  Q_REASON="${QUARANTINE_DIR}/${STEM}.reason.txt"
  cat "$BODY_TMP" > "$Q_DEST"
  printf '%s\n' "$REASON" > "$Q_REASON"
  echo "$Q_DEST" >&2
  exit 1
fi
