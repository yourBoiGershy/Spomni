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
# Perf refactor (plan 27 U1, D4; F4 fix-round correction): a scratch
# workspace holds (a) two sender-haystack snapshots, greped once per hint
# instead of re-grepping their source(s) per hint — SENDER_HAYSTACK
# (index.json + people/*.md, for the email check) and
# SENDER_HAYSTACK_PEOPLE (people/*.md only, for the name-part check — pre-
# U1 semantics: a name_part match only ever counted against people/*.md,
# never index.json, and the U1 refactor must not silently widen that) —
# and (b) the ledger partition files built once at startup instead of
# per-event grep/awk.
# ---------------------------------------------------------------------------

WORKTMP="$(mktemp -d "${TMPDIR:-/tmp}/triage-inbox.XXXXXX")"
cleanup_worktmp() {
  rm -rf "$WORKTMP"
}
trap cleanup_worktmp EXIT

SENDER_HAYSTACK="${WORKTMP}/sender-haystack"
SENDER_HAYSTACK_PEOPLE="${WORKTMP}/sender-haystack-people"
: > "$SENDER_HAYSTACK"
: > "$SENDER_HAYSTACK_PEOPLE"
if [ -f "$INDEX_JSON" ]; then
  cat "$INDEX_JSON" >> "$SENDER_HAYSTACK" 2>/dev/null || true
fi
if [ -d "$PEOPLE_DIR" ]; then
  find "$PEOPLE_DIR" -type f -exec cat {} + >> "$SENDER_HAYSTACK" 2>/dev/null || true
  find "$PEOPLE_DIR" -type f -exec cat {} + >> "$SENDER_HAYSTACK_PEOPLE" 2>/dev/null || true
fi

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
# Note: [[:space:]] (POSIX class), not [ \t] — BSD/macOS sed has no \t
# escape inside a bracket expression there, so [ \t] would match only the
# three literal characters space/backslash/t (and never a real tab),
# silently mis-trimming the subject.
extract_subject() {
  printf '%s\n' "$1" | grep -m1 -i '^Subject:' | sed -n 's/^[Ss][Uu][Bb][Jj][Ee][Cc][Tt]:[[:space:]]*//p'
}

# sender_known <hints-newline-list> — 0 (true/known) if any hint's email
# address or display-name text appears in index.json or people/*.md; 1
# (unknown) otherwise. No hints at all is indeterminate, which per the
# precision-first doctrine is treated as "known" (safe direction: never
# fires cold-pitch without positive unknown-sender evidence).
#
# Perf: index.json + people/*.md were snapshotted once into
# $SENDER_HAYSTACK at startup (see above), and people/*.md alone into
# $SENDER_HAYSTACK_PEOPLE — the email check greps the combined haystack,
# the name-part check greps the people-only haystack (matching this
# function's original per-hint semantics: a name match only ever counted
# against people/*.md, never index.json), instead of re-reading
# INDEX_JSON/PEOPLE_DIR per hint.
sender_known() {
  hints="$1"
  [ -z "$hints" ] && return 0

  found=0
  while IFS= read -r hint; do
    [ -z "$hint" ] && continue

    email="$(printf '%s' "$hint" | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1)"
    if [ -n "$email" ]; then
      if [ -s "$SENDER_HAYSTACK" ] && grep -qiF -- "$email" "$SENDER_HAYSTACK" 2>/dev/null; then
        found=1
      fi
    fi

    if [ "$found" -eq 0 ]; then
      name_part="$(printf '%s' "$hint" | sed -n 's/^\([^<]*\)<.*/\1/p' | sed 's/[[:space:]]*$//')"
      [ -z "$name_part" ] && name_part="$hint"
      if [ -n "$name_part" ] && [ -s "$SENDER_HAYSTACK_PEOPLE" ] && grep -qiF -- "$name_part" "$SENDER_HAYSTACK_PEOPLE" 2>/dev/null; then
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
#
# Pattern source of truth: the five rule regexes below are duplicated
# verbatim (shell-safe form) from packages/ingestion/specs/import-triage.md
# "The five rule classes" (and its "Pattern source of truth" note). That
# spec section is authoritative — any pattern content change MUST land in
# the spec and here in the same commit.
# ---------------------------------------------------------------------------

held=0
rule_noreply=0
rule_selfcal=0
rule_otp=0
rule_li=0
rule_cold=0

# --- one-pass ledger partition (D4a): candidate ids are listed once, the
# already-filed/already-held skip sets are built once from the ledgers, and
# the eligible-for-rule-evaluation set is computed with a single
# grep -vxF -f pass instead of a per-event grep/awk. ---------------------

ID_LIST="${WORKTMP}/ids"
: > "$ID_LIST"
for f in $(ls "$INBOX_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  printf '%s\n' "${base%.md}" >> "$ID_LIST"
done
scanned="$(wc -l < "$ID_LIST" | tr -d ' ')"

FILED_SKIP="${WORKTMP}/filed-skip"
: > "$FILED_SKIP"
if [ -f "$FILED_LOG" ]; then
  sort -u "$FILED_LOG" > "$FILED_SKIP" 2>/dev/null || : > "$FILED_SKIP"
fi

HELD_SKIP="${WORKTMP}/held-skip"
: > "$HELD_SKIP"
if [ -f "$HELD_LOG" ]; then
  cut -f1 "$HELD_LOG" 2>/dev/null | sort -u > "$HELD_SKIP" || : > "$HELD_SKIP"
fi

COMBINED_SKIP="${WORKTMP}/combined-skip"
cat "$FILED_SKIP" "$HELD_SKIP" 2>/dev/null | sort -u > "$COMBINED_SKIP" || : > "$COMBINED_SKIP"

# skip_matches <ids-file> <skip-file> — ids from ids-file present in
# skip-file (fixed-string, whole-line match). Empty skip-file -> no output.
skip_matches() {
  if [ -s "$2" ]; then
    grep -xF -f "$2" "$1" 2>/dev/null || true
  fi
}

# skip_filter <ids-file> <skip-file> — ids from ids-file NOT present in
# skip-file. Empty skip-file -> ids-file unchanged.
skip_filter() {
  if [ -s "$2" ]; then
    grep -vxF -f "$2" "$1" 2>/dev/null || true
  else
    cat "$1"
  fi
}

already_filed="$(skip_matches "$ID_LIST" "$FILED_SKIP" | wc -l | tr -d ' ')"

AFTER_FILED="${WORKTMP}/after-filed"
skip_filter "$ID_LIST" "$FILED_SKIP" > "$AFTER_FILED"

already_held="$(skip_matches "$AFTER_FILED" "$HELD_SKIP" | wc -l | tr -d ' ')"

ELIGIBLE_IDS="${WORKTMP}/eligible"
skip_filter "$ID_LIST" "$COMBINED_SKIP" > "$ELIGIBLE_IDS"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  f="${INBOX_DIR}/${id}.md"
  [ -e "$f" ] || continue

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
done < "$ELIGIBLE_IDS"

printf 'triage: scanned=%d held=%d already-filed=%d already-held=%d per-rule=noreply-marketing:%d,self-only-calendar:%d,otp-security:%d,linkedin-invitation:%d,cold-pitch:%d\n' \
  "$scanned" "$held" "$already_filed" "$already_held" \
  "$rule_noreply" "$rule_selfcal" "$rule_otp" "$rule_li" "$rule_cold"

exit 0
