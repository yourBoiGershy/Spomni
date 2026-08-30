#!/usr/bin/env bash
# triage-inbox.sh — deterministic pre-judgment triage pass over inbox/,
# implementing packages/ingestion/specs/import-triage.md's five rule
# classes (first-match-wins, precision-first: any doubt falls through to
# normal debrief judgment, never held).
#
# Usage:
#   triage-inbox.sh <store-dir> [--data-dir <dir>] [--dry-run]
#
# <store-dir>/inbox/*.md is scanned (never inbox/quarantine/). Events whose
# id already appears in <data-dir>/debrief-filed.log or
# <data-dir>/triage-held.log are skipped (counted separately, not re-held).
# On a rule match, appends the D3 ledger line to
# <data-dir>/triage-held.log:
#
#   <capture-id>\t<rule-name>\t<held-at ISO 8601 Z>
#
# --dry-run prints the would-be ledger line to stdout instead of writing —
# no file is created or modified in dry-run mode. Real runs are idempotent:
# an id already in triage-held.log is skipped on a later run (never
# re-held, never a duplicate line).
#
# Ends with exactly one summary line to stdout, every terminal state
# covered (including an empty inbox):
#   triage: scanned=<n> held=<n> already-filed=<n> already-held=<n> per-rule=<rule>:<n>,...
#
# Exit 0 on a completed scan (held=0 is success); non-zero only on
# usage/IO errors (missing store-dir, missing inbox/, missing jq).
#
# Writes only <data-dir>/triage-held.log. inbox/ is never touched, in
# either direction. Portable to bash 3.2 (macOS default): no associative
# arrays, no mapfile, no ${var,,}.

set -eu

usage() {
  echo "usage: triage-inbox.sh <store-dir> [--data-dir <dir>] [--dry-run]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
shift

DATA_DIR="data/ingestion"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "triage-inbox.sh: --data-dir requires an argument" >&2
        exit 1
      fi
      DATA_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "triage-inbox.sh: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "triage-inbox.sh: jq is required but not found on PATH" >&2
  exit 1
fi

INBOX_DIR="${STORE_DIR}/inbox"
if [ ! -d "$INBOX_DIR" ]; then
  echo "triage-inbox.sh: ${INBOX_DIR}: no such inbox directory" >&2
  exit 1
fi

FILED_LOG="${DATA_DIR}/debrief-filed.log"
HELD_LOG="${DATA_DIR}/triage-held.log"
INDEX_JSON="${STORE_DIR}/index.json"
PEOPLE_DIR="${STORE_DIR}/people"

# ---------------------------------------------------------------------------
# Frontmatter / body helpers (same shape as build-index.sh / derive-
# participation.sh's awk passes over the same capture-event/person files).
# ---------------------------------------------------------------------------

# extract_frontmatter <file> — the block between the first two '---' lines.
extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

# extract_body <file> — everything after the frontmatter's closing '---'.
extract_body() {
  awk '
    /^---$/ { n++; next }
    n >= 2 { print }
  ' "$1"
}

# get_field <frontmatter-text> <key> — a single scalar frontmatter value.
get_field() {
  printf '%s\n' "$1" | sed -n "s/^${2}: *//p" | head -1
}

# extract_hints <frontmatter-text> — participant-hints list entries, one
# per line, quotes stripped.
extract_hints() {
  awk '
    BEGIN { in_hints = 0 }
    {
      if ($0 ~ /^participant-hints:/) { in_hints = 1; next }
      if (in_hints == 1) {
        if ($0 ~ /^[ \t]+-[ \t]/) {
          v = $0
          sub(/^[ \t]+-[ \t]*/, "", v)
          gsub(/^"|"$/, "", v)
          print v
          next
        } else {
          in_hints = 0
        }
      }
    }
  ' <<EOF_HINTS
$1
EOF_HINTS
}

# extract_subject <body-text> — the first "Subject: ..." line's value.
extract_subject() {
  printf '%s\n' "$1" | grep -m1 -i '^Subject:' | sed -n 's/^[Ss]ubject:[ \t]*//p'
}

# sender_known <hints-newline-list> — 0 (true/known) if any hint's email
# address or display-name text appears in index.json or people/*.md; 1
# (unknown) otherwise. No hints at all is indeterminate, which per the
# precision-first doctrine is treated as "known" (safe direction: never
# fires cold-pitch without positive unknown-sender evidence).
sender_known() {
  hints="$1"
  [ -z "$hints" ] && return 0

  found=0
  while IFS= read -r hint; do
    [ -z "$hint" ] && continue

    email="$(printf '%s' "$hint" | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1)"
    if [ -n "$email" ]; then
      if [ -f "$INDEX_JSON" ] && grep -qiF -- "$email" "$INDEX_JSON" 2>/dev/null; then
        found=1
      fi
      if [ "$found" -eq 0 ] && [ -d "$PEOPLE_DIR" ] && grep -RqiF -- "$email" "$PEOPLE_DIR" 2>/dev/null; then
        found=1
      fi
    fi

    if [ "$found" -eq 0 ]; then
      name_part="$(printf '%s' "$hint" | sed -n 's/^\([^<]*\)<.*/\1/p' | sed 's/[ \t]*$//')"
      [ -z "$name_part" ] && name_part="$hint"
      if [ -n "$name_part" ] && [ -d "$PEOPLE_DIR" ] && grep -RqiF -- "$name_part" "$PEOPLE_DIR" 2>/dev/null; then
        found=1
      fi
    fi
  done <<EOF_SENDER
$hints
EOF_SENDER

  [ "$found" -eq 1 ]
}

# thread_has_no_reply_markers <body-text> <subject> — 0 (true) if the body
# carries no In-Reply-To:/References: header and the subject is not a
# Re:/Fwd: reply form.
thread_has_no_reply_markers() {
  body="$1"
  subject="$2"
  if printf '%s\n' "$body" | grep -Eqi '^(In-Reply-To|References):'; then
    return 1
  fi
  if printf '%s' "$subject" | grep -Eqi '^(re|fwd?)[:]'; then
    return 1
  fi
  return 0
}

# cold_pitch_match <body-text> <subject> <hints> — the combined cold-pitch
# predicate: single-message thread AND unknown sender AND strong phrasing.
cold_pitch_match() {
  body="$1"
  subject="$2"
  hints="$3"

  if ! thread_has_no_reply_markers "$body" "$subject"; then
    return 1
  fi
  if sender_known "$hints"; then
    return 1
  fi

  combined="${subject} ${body}"
  printf '%s' "$combined" | grep -Eqi '(quick (question|intro)|are you the right person|i (came across|noticed) your (company|profile)|book a (demo|call)|unsubscribe (from this list|here)|following up on my (last|previous) (email|message)|reaching out because)'
}

# ---------------------------------------------------------------------------
# Main scan
# ---------------------------------------------------------------------------

scanned=0
held=0
already_filed=0
already_held=0
rule_noreply=0
rule_selfcal=0
rule_otp=0
rule_li=0
rule_cold=0

for f in $(ls "$INBOX_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue

  base="$(basename "$f")"
  id="${base%.md}"
  scanned=$((scanned + 1))

  if [ -f "$FILED_LOG" ] && grep -qxF "$id" "$FILED_LOG" 2>/dev/null; then
    already_filed=$((already_filed + 1))
    continue
  fi

  if [ -f "$HELD_LOG" ] && awk -F'\t' -v id="$id" '$1 == id { f = 1 } END { exit !f }' "$HELD_LOG"; then
    already_held=$((already_held + 1))
    continue
  fi

  fm="$(extract_frontmatter "$f")"
  type="$(get_field "$fm" type)"
  body="$(extract_body "$f")"
  hints="$(extract_hints "$fm")"

  rule=""

  # 1. noreply-marketing (type: email only)
  if [ -z "$rule" ] && [ "$type" = "email" ]; then
    if printf '%s\n' "$hints" | grep -Eqi '(no-?reply|do-?not-?reply|donotreply|newsletter|marketing|notifications?)@'; then
      rule="noreply-marketing"
    else
      from_header="$(printf '%s\n' "$body" | grep -m1 -Ei '^From:' || true)"
      if [ -n "$from_header" ] && printf '%s' "$from_header" | grep -Eqi '(no-?reply|do-?not-?reply|donotreply|newsletter|marketing|notifications?)@'; then
        rule="noreply-marketing"
      fi
    fi
  fi

  # 2. self-only-calendar (type: calendar-event only)
  if [ -z "$rule" ] && [ "$type" = "calendar-event" ]; then
    other_count="$(printf '%s' "$body" | jq -r '(.attendees // []) | map(select((.self // false) | not)) | length' 2>/dev/null || echo "")"
    if [ "$other_count" = "0" ]; then
      rule="self-only-calendar"
    fi
  fi

  # 3. otp-security (type: email only)
  if [ -z "$rule" ] && [ "$type" = "email" ]; then
    subject="$(extract_subject "$body")"
    if printf '%s' "$subject" | grep -Eqi '(verification code|one-?time (code|passcode)|otp|security alert|new sign-?in|sign-?in attempt|confirm your (email|account)|2fa|two-?factor)'; then
      rule="otp-security"
    fi
  fi

  # 4. linkedin-invitation (type: linkedin-notification, or type: email
  # from a linkedin.com sender)
  if [ -z "$rule" ]; then
    li_candidate=0
    if [ "$type" = "linkedin-notification" ]; then
      li_candidate=1
    elif [ "$type" = "email" ]; then
      if printf '%s\n' "$hints" | grep -Eqi '@[a-z0-9.-]*linkedin\.com'; then
        li_candidate=1
      fi
    fi
    if [ "$li_candidate" -eq 1 ]; then
      subject="$(extract_subject "$body")"
      if printf '%s' "$subject" | grep -Eqi '(wants to connect|invitation to connect|accepted your invitation|connection request)'; then
        rule="linkedin-invitation"
      fi
    fi
  fi

  # 5. cold-pitch (type: email only; weakest rule, all sub-conditions
  # required)
  if [ -z "$rule" ] && [ "$type" = "email" ]; then
    subject="$(extract_subject "$body")"
    if cold_pitch_match "$body" "$subject" "$hints"; then
      rule="cold-pitch"
    fi
  fi

  if [ -n "$rule" ]; then
    held=$((held + 1))
    case "$rule" in
      noreply-marketing) rule_noreply=$((rule_noreply + 1)) ;;
      self-only-calendar) rule_selfcal=$((rule_selfcal + 1)) ;;
      otp-security) rule_otp=$((rule_otp + 1)) ;;
      linkedin-invitation) rule_li=$((rule_li + 1)) ;;
      cold-pitch) rule_cold=$((rule_cold + 1)) ;;
    esac

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="$(printf '%s\t%s\t%s' "$id" "$rule" "$ts")"

    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s\n' "$line"
    else
      mkdir -p "$DATA_DIR"
      printf '%s\n' "$line" >> "$HELD_LOG"
    fi
  fi
done

printf 'triage: scanned=%d held=%d already-filed=%d already-held=%d per-rule=noreply-marketing:%d,self-only-calendar:%d,otp-security:%d,linkedin-invitation:%d,cold-pitch:%d\n' \
  "$scanned" "$held" "$already_filed" "$already_held" \
  "$rule_noreply" "$rule_selfcal" "$rule_otp" "$rule_li" "$rule_cold"

exit 0
