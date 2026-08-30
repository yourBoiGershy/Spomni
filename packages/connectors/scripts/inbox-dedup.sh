#!/bin/bash
# inbox-dedup.sh — rebuild <store-dir>/inbox/.fingerprints and, on request,
# prune already-landed byte-identical duplicate captures.
#
# Usage:
#   inbox-dedup.sh <store-dir> [--apply] [--private-data-root <p>]
#
# Mission: cuts a remembering-to/cleanup chore (byte-identical re-captures
# piling up in inbox/, e.g. a re-fetched page with a new captured_at) —
# never an ingredient. "Raw kept forever" is honoured: only a byte-identical
# LATER copy is ever removed, and never one that has already been filed
# (its id appears in debrief-filed.log) — filed history is not "raw kept
# forever" collateral, it is the whole point of capture.
#
# Rebuild: scans every <store-dir>/inbox/*.md (quarantine/ is a directory,
# never touched — the glob never enters it), hashing each body the same way
# check-sync.sh's "Byte-identical bodies" check and normalize-capture.sh's
# dedup index do (body = everything after the frontmatter's closing '---'),
# ordered by filename ascending (ids are captured_at-prefixed, so earliest
# wins as keeper). Empty bodies are never deduplicated. For every hash seen
# more than once, the first (earliest) id is the keeper; every later id with
# that hash is reported: `dup: <later-id> == <keeper-id>`.
#
# Without --apply: report-only. Prints one `dup:` line per duplicate found
# and a final summary line, does not touch disk otherwise (other than
# writing the rebuilt .fingerprints index, which is always current-on-disk
# truth, never destructive).
#
# With --apply: deletes each duplicate .md file, EXCEPT any whose id appears
# in column 1 of <private-data-root>/data/ingestion/debrief-filed.log (that
# capture has already been filed into people/interactions — removing the
# raw would sever provenance for something the store already relies on).
# Those are printed as `keep-filed: <id>` and left alone. Default
# private-data-root is <store-dir>/../.. (missing debrief-filed.log means
# nothing has been filed yet — nothing is exempt). After deletion, rebuilds
# .fingerprints again from the post-delete disk state.
#
# Exit 0 on a normal run (with or without duplicates found). Exit 2 on
# usage error. Never touches inbox/quarantine/.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

STORE_DIR="${1:-}"
if [ -z "$STORE_DIR" ]; then
  echo "inbox-dedup.sh: <store-dir> is required" >&2
  exit 2
fi
shift

APPLY=0
PRIVATE_DATA_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --private-data-root)
      PRIVATE_DATA_ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "inbox-dedup.sh: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

INBOX_DIR="${STORE_DIR}/inbox"
FP_FILE="${INBOX_DIR}/.fingerprints"

if [ ! -d "$INBOX_DIR" ]; then
  echo "inbox-dedup.sh: no inbox/ directory at ${INBOX_DIR}" >&2
  exit 2
fi

if [ -z "$PRIVATE_DATA_ROOT" ]; then
  PRIVATE_DATA_ROOT="${STORE_DIR}/../.."
fi

hash_body() {
  # $1 = path to a file containing just the body to hash.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# rebuild_index — writes hash<TAB>id to <store-dir>/inbox/.fingerprints for
# every non-empty-body *.md event, ordered by filename ascending.
# ---------------------------------------------------------------------------
rebuild_index() {
  FP_TMP="$(mktemp)"
  for f in "$INBOX_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    fm_close="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$f")"
    [ -n "$fm_close" ] || continue
    body_tmp="$(mktemp)"
    tail -n "+$((fm_close + 1))" "$f" > "$body_tmp"
    if [ -s "$body_tmp" ]; then
      printf '%s\t%s\n' "$(hash_body "$body_tmp")" "$base" >> "$FP_TMP"
    fi
    rm -f "$body_tmp"
  done
  sort -k2,2 "$FP_TMP" > "${FP_TMP}.sorted"
  mv "${FP_TMP}.sorted" "$FP_FILE"
  rm -f "$FP_TMP"
}

rebuild_index

# ---------------------------------------------------------------------------
# Find duplicates: for each hash seen more than once (in filename order —
# .fingerprints is sorted by id above), the first is the keeper, the rest
# are duplicates.
# ---------------------------------------------------------------------------
find_dups() {
  # Emits "<dup-id>\t<keeper-id>" per duplicate, sorted by id (filename)
  # ascending so the earliest occurrence per hash is always the keeper.
  sort -k1,1 -k2,2 "$FP_FILE" | awk -F'\t' '
    $1 == prev_hash { print $2 "\t" keeper; next }
    { prev_hash = $1; keeper = $2 }
  '
}

DUPS_TMP="$(mktemp)"
find_dups > "$DUPS_TMP"

DUP_COUNT=$(wc -l < "$DUPS_TMP" | tr -d ' ')

if [ "$APPLY" -eq 0 ]; then
  while IFS="$(printf '\t')" read -r dup_id keeper_id; do
    [ -n "$dup_id" ] || continue
    printf 'dup: %s == %s\n' "$dup_id" "$keeper_id"
  done < "$DUPS_TMP"
  printf 'inbox-dedup: %s duplicates (%s filed, kept)\n' "$DUP_COUNT" 0
  rm -f "$DUPS_TMP"
  exit 0
fi

# ---------------------------------------------------------------------------
# --apply: delete duplicates, except ids already filed (debrief-filed.log).
# ---------------------------------------------------------------------------
FILED_LOG="${PRIVATE_DATA_ROOT}/data/ingestion/debrief-filed.log"
FILED_IDS_TMP="$(mktemp)"
if [ -f "$FILED_LOG" ]; then
  cut -f1 "$FILED_LOG" | sort -u > "$FILED_IDS_TMP"
else
  : > "$FILED_IDS_TMP"
fi

REMOVED_COUNT=0
FILED_COUNT=0

while IFS="$(printf '\t')" read -r dup_id keeper_id; do
  [ -n "$dup_id" ] || continue
  if grep -Fxq "$dup_id" "$FILED_IDS_TMP" 2>/dev/null; then
    printf 'keep-filed: %s\n' "$dup_id"
    FILED_COUNT=$((FILED_COUNT + 1))
    continue
  fi
  printf 'dup: %s == %s\n' "$dup_id" "$keeper_id"
  rm -f "${INBOX_DIR}/${dup_id}.md"
  REMOVED_COUNT=$((REMOVED_COUNT + 1))
done < "$DUPS_TMP"

rm -f "$DUPS_TMP" "$FILED_IDS_TMP"

printf 'inbox-dedup: %s duplicates (%s filed, kept)\n' "$DUP_COUNT" "$FILED_COUNT"

# Reflect post-delete disk state.
rebuild_index

printf 'inbox-dedup: removed %s\n' "$REMOVED_COUNT"
exit 0
