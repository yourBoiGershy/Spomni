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
# Exit 3 on a byte-identical duplicate of a body already in inbox/ (prints
# the EXISTING inbox path to stdout, a reason to stderr) — nothing is
# written and nothing is quarantined. Empty bodies are never deduplicated
# (capture is lossy-tolerant; an empty capture is not "the same" as another
# empty capture). Dedup state lives in <store-dir>/inbox/.fingerprints, a
# dot-prefixed (so validators/check-sync ignore it) append-only TSV of
# `sha256(body)<TAB>id`, rebuilt from disk the first time it's missing.
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
  # Sanitize the source component for filename/id safety: replace any
  # path-unsafe character (/, whitespace) with '-' so the id always stays a
  # flat filename. The frontmatter 'source:' field keeps the original,
  # unsanitized value — the id form is a convenience, not authoritative.
  SAFE_SOURCE="$(printf '%s' "$SOURCE" | tr -s '/ \t' '-')"
  ID="$(captured_at_compact "$CAPTURED_AT")-${SAFE_SOURCE}-$(rand_hex4)"
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
  voice-note|linkedin-notification|event-confirmation|transcript|other|email|calendar-event|profile-snapshot|contact-record|post|chat-message)
    ;;
  *)
    add_reason "invalid type: '${TYPE}' (expected one of: voice-note, linkedin-notification, event-confirmation, transcript, other, email, calendar-event, profile-snapshot, contact-record, post, chat-message)"
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
    printf 'schema_version: 1.2.0\n'
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

hash_body() {
  # $1 = path to a file containing just the body to hash.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Dedup: refuse a byte-identical body already in inbox/. Only when the
# event would otherwise be written and the body is non-empty.
# ---------------------------------------------------------------------------

FP_FILE="${INBOX_DIR}/.fingerprints"
BODY_HASH=""

if [ "$VALID" -eq 1 ] && [ -s "$BODY_TMP" ]; then
  BODY_HASH="$(hash_body "$BODY_TMP")"

  if [ ! -e "$FP_FILE" ]; then
    # Build the index once from whatever is already on disk. Body = every
    # line after the frontmatter's closing '---', matching check-sync.sh's
    # "Byte-identical bodies" extraction so hashes agree across tools.
    FP_TMP="$(mktemp)"
    for existing in "$INBOX_DIR"/*.md; do
      [ -e "$existing" ] || continue
      existing_base="$(basename "$existing" .md)"
      fm_close="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$existing")"
      if [ -n "$fm_close" ]; then
        existing_body_tmp="$(mktemp)"
        tail -n "+$((fm_close + 1))" "$existing" > "$existing_body_tmp"
        if [ -s "$existing_body_tmp" ]; then
          printf '%s\t%s\n' "$(hash_body "$existing_body_tmp")" "$existing_base" >> "$FP_TMP"
        fi
        rm -f "$existing_body_tmp"
      fi
    done
    mv "$FP_TMP" "$FP_FILE"
  fi

  FP_HIT="$(grep -F "$(printf '%s\t' "$BODY_HASH")" "$FP_FILE" 2>/dev/null | head -n1)"
  if [ -n "$FP_HIT" ]; then
    DUP_ID="$(printf '%s' "$FP_HIT" | cut -f2)"
    printf '%s\n' "${INBOX_DIR}/${DUP_ID}.md"
    echo "normalize-capture.sh: duplicate body of ${DUP_ID} — not written" >&2
    exit 3
  fi
fi

if [ "$VALID" -eq 1 ]; then
  DEST="${INBOX_DIR}/${ID}.md"
  if ! write_frontmatter "$DEST"; then
    echo "normalize-capture.sh: failed to write inbox event: $DEST" >&2
    exit 1
  fi
  if ! cat "$BODY_TMP" >> "$DEST"; then
    echo "normalize-capture.sh: failed to append body to inbox event: $DEST" >&2
    exit 1
  fi
  if [ ! -e "$DEST" ]; then
    echo "normalize-capture.sh: inbox event missing after write: $DEST" >&2
    exit 1
  fi
  if [ -n "$BODY_HASH" ]; then
    printf '%s\t%s\n' "$BODY_HASH" "$ID" >> "$FP_FILE"
  fi
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
