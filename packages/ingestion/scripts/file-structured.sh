#!/usr/bin/env bash
# file-structured.sh — deterministic filer for calendar-event and
# metadata-only gmail capture events, no model call in the loop
# (packages/ingestion/specs/structured-filing.md, plan 31 D1/D2/D3).
#
# Usage:
#   file-structured.sh <store-dir> [--data-dir <dir>] [--today YYYY-MM-DD]
#                       [--dry-run] [--no-index] [--relearn]
#
# <store-dir> holds inbox/, people/, interactions/, index.json. --data-dir
# defaults to "<store-dir>/.." and roots three ledgers under
# <data-dir>/ingestion/: debrief-filed.log (shared with the debrief skill's
# batch mode — this filer appends to the SAME ledger so debrief skips what
# was filed here), triage-held.log (read-only, another skip source), and
# structured-held.log (this script's own D3 hold ledger, sole writer).
# Self identities come from <data-dir>/config/onboarding-backfill.tsv rows
# "self<TAB><identity>", and bot/noreply identities to drop the same way
# come from "ignore<TAB><identity>" rows in the same file (file may be
# absent — no exclusion then).
#
# Eligibility (see the spec for the full model): `type: calendar-event`, or
# `source` starting with "gmail-in/" whose body — after dropping a single
# leading "Subject: ..." line — is under 40 words. Everything else is left
# for the model filing path. Ids already in any of the three ledgers are
# skipped (single grep -vxF -f pass, never a per-event grep).
#
# Resolution mirrors shard-filing-batch.sh's identity_resolve_email/
# identity_resolve_name (duplicated here per that script's own "no sync
# mechanism between copies" precedent, not sourced): exact email or exact
# normalized-name match against people/*.md + index.json +
# <data-dir>/ingestion/identities.tsv (a persistent learned email<->slug
# map this filer writes to and reads from — see below). A calendar-event
# hint with no display name of its own borrows one from the calendar
# body's attendees/organizer/creator before resolving, so a bare-email
# calendar attendee only holds if NEITHER the hint NOR the body names them.
# A hint that matches >=2 people by name holds the whole event
# (ambiguous-name); an email hint with no name anywhere holds it too
# (no-name). Self hints are dropped first; an event with zero non-self
# hints left is skipped, nothing written.
#
# Identity learning: whenever an email hint resolves to a slug (existing
# match or newly created), the pair is appended to
# <data-dir>/ingestion/identities.tsv (<slug>	EMAIL	<capture-id>,
# append-only, deduped by slug+email) so a later bare-email hint for that
# same person — most commonly a gmail sender/recipient with no display
# name at all — resolves too. An email hint with no name anywhere AND an
# unknown address still gets one more chance before holding: if its
# local-part is EITHER a single letters-only token of >=3 letters (e.g.
# "patrick", "christian" — a live-corpus rebalance: plain first-name
# local-parts dominate real calendars and holding them buys nothing, the
# model path has no more information than the local-part either) OR 2-3
# letters-only dot/underscore/hyphen-separated tokens each >=2 letters
# (e.g. "thomas.wright"), a person is created with that title-cased name
# and `tags: [name-from-email]` (visibly provisional) and the pairing is
# learned; a 1-2-letter single token ("jo", "a"), a 1-letter token inside
# a multi-token split ("a.bhandhoal"), or anything else (digits, role
# addresses) still holds no-name.
# When identities.tsv is missing (first run) or --relearn is given, a
# bootstrap pass derives pairs from the existing interactions/*.md + their
# source inbox/ events first: forced 1-slug+1-email interactions, N-slug+
# N-email interactions where a display name uniquely matches one slug,
# and then constraint propagation to a fixed point — for every multi-
# attendee interaction, drop every email/slug already resolved by ANY
# other pairing learned so far (from any interaction) and re-check for a
# 1:1 residual, repeating until a round learns nothing. This is what lets
# an already-known Dhruv+Josh in a 3-person meeting force out Christian's
# email even though that meeting alone was never 1:1. Never guesses beyond
# a forced 1:1. Prints "identities: learned=<n>" before the main summary
# line. --dry-run never touches identities.tsv (no bootstrap, no
# learning) — consistent with --dry-run writing nothing anywhere.
#
# Writes: new people/<slug>.md (person.md 1.1.0 shape, name + last-touch
# only — no Facts bullets, ever, per D2), last-touch bumps on existing
# people (only forward in time), interactions/<date>-<slug>[--n].md, and
# appends to debrief-filed.log (filed) or structured-held.log (held).
# Unless --dry-run or --no-index, ends with one reindex.sh run (index.json
# + stats.json, plan 38 D2).
#
# --dry-run prints the summary line plus one "would-file <id> -> <slugs>"
# line per event that would have been filed; writes nothing.
#
# Ends with exactly one summary line to stdout, every terminal state
# covered:
#   file-structured: eligible=<n> filed=<n> people_new=<n> held=<n> skipped=<n>
#
# Exit 0 on a completed pass; non-zero only on usage/IO errors (missing
# store-dir, missing inbox/, missing jq). Portable to bash 3.2 (macOS
# default): no associative arrays, no mapfile, no ${var,,}.

set -u

usage() {
  echo "usage: file-structured.sh <store-dir> [--data-dir <dir>] [--today YYYY-MM-DD] [--dry-run] [--no-index] [--relearn]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
shift

DATA_DIR=""
TODAY=""
DRY_RUN=0
NO_INDEX=0
RELEARN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "file-structured.sh: --data-dir requires an argument" >&2
        exit 1
      fi
      DATA_DIR="$2"
      shift 2
      ;;
    --today)
      if [ $# -lt 2 ]; then
        echo "file-structured.sh: --today requires an argument" >&2
        exit 1
      fi
      TODAY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-index)
      NO_INDEX=1
      shift
      ;;
    --relearn)
      RELEARN=1
      shift
      ;;
    *)
      echo "file-structured.sh: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

[ -n "$DATA_DIR" ] || DATA_DIR="${STORE_DIR}/.."

if [ -n "$TODAY" ] && ! printf '%s' "$TODAY" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  echo "file-structured.sh: invalid --today: '${TODAY}' (expected ISO 8601 date YYYY-MM-DD)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "file-structured.sh: jq is required but not found on PATH" >&2
  exit 1
fi

INBOX_DIR="${STORE_DIR}/inbox"
if [ ! -d "$INBOX_DIR" ]; then
  echo "file-structured.sh: ${INBOX_DIR}: no such inbox directory" >&2
  exit 1
fi

PEOPLE_DIR="${STORE_DIR}/people"
INTERACTIONS_DIR="${STORE_DIR}/interactions"
INDEX_JSON="${STORE_DIR}/index.json"
ING_DIR="${DATA_DIR}/ingestion"
FILED_LOG="${ING_DIR}/debrief-filed.log"
TRIAGE_HELD_LOG="${ING_DIR}/triage-held.log"
STRUCT_HELD_LOG="${ING_DIR}/structured-held.log"
IDENTITIES_TSV="${ING_DIR}/identities.tsv"
CONFIG_TSV="${DATA_DIR}/config/onboarding-backfill.tsv"

if [ -n "$TODAY" ]; then
  HELD_AT="${TODAY}T00:00:00Z"
else
  HELD_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

WORKTMP="$(mktemp -d "${TMPDIR:-/tmp}/file-structured.XXXXXX")"
cleanup_worktmp() {
  rm -rf "$WORKTMP"
}
trap cleanup_worktmp EXIT

if [ "$DRY_RUN" -ne 1 ]; then
  mkdir -p "$ING_DIR" "$PEOPLE_DIR" "$INTERACTIONS_DIR"
fi

# ---------------------------------------------------------------------------
# Frontmatter/body helpers — same shape as triage-inbox.sh's / shard-
# filing-batch.sh's (duplicated per those scripts' own "no sync mechanism
# between copies" precedent).
# ---------------------------------------------------------------------------

extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

extract_body() {
  awk '
    /^---$/ { n++; next }
    n >= 2 { print }
  ' "$1"
}

get_field() {
  printf '%s\n' "$1" | sed -n "s/^${2}: *//p" | head -1
}

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

# extract_subject <body-text> — first "Subject: ..." line's value.
extract_subject() {
  printf '%s\n' "$1" | grep -m1 -i '^Subject:' | sed -n 's/^[Ss][Uu][Bb][Jj][Ee][Cc][Tt]:[[:space:]]*//p'
}

# body_word_count <body-text> — word count after dropping a leading
# "Subject: ..." line only (never a later one).
body_word_count() {
  printf '%s\n' "$1" | awk 'NR == 1 && /^Subject:/ { next } { print }' | wc -w | tr -d ' '
}

# gmail_subject_and_wordcount <body-text> — ONE awk pass producing
# "subject\tword_count" (word count after dropping the leading
# "Subject: ..." line) — replaces separate extract_subject + 
# body_word_count forks (each event needs both: word count for the
# eligibility gate, subject for the Email summary — one call, used twice).
gmail_subject_and_wordcount() {
  printf '%s\n' "$1" | awk '
    NR == 1 && /^[Ss][Uu][Bb][Jj][Ee][Cc][Tt]:/ {
      v = $0
      sub(/^[Ss][Uu][Bb][Jj][Ee][Cc][Tt]:[ \t]*/, "", v)
      subj = v
      next
    }
    { wc += NF }
    END { printf "%s\t%d\n", subj, wc + 0 }
  '
}

# parse_hint <hint> — sets HINT_EMAIL (first email-looking substring,
# lowercased, may be empty) and HINT_DISPLAY_NAME (text before "<...>",
# trimmed; empty if the hint has no angle-bracket form). One awk process
# per call (perf: this runs per hint per event — the 275-event budget
# leaves no room for parse_hint's original 4-subshell form).
parse_hint() {
  hint="$1"
  HINT_PARSED="$(printf '%s' "$hint" | awk '
    {
      email = ""
      if (match($0, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
        email = tolower(substr($0, RSTART, RLENGTH))
      }
      name = ""
      if (match($0, /^[^<]*</)) {
        name = substr($0, 1, RSTART + RLENGTH - 2)
        gsub(/[ \t]+$/, "", name)
      }
      printf "%s\t%s", email, name
    }
  ')"
  HINT_EMAIL="${HINT_PARSED%%	*}"
  HINT_DISPLAY_NAME="${HINT_PARSED#*	}"
}

normalize_email() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Note: [[:space:]] (POSIX class), not [ \t] — BSD/macOS sed has no \t
# escape inside a bracket expression.
normalize_name() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g'
}

# kebab <name> — kebab-case a display name (same rule as validate-store.sh).
kebab() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# email_local_name <email> — coordinator follow-up point 2 (rebalanced
# per live-corpus evidence, plan 31 D3 follow-up): an email that is
# otherwise unresolvable and unnamed gets a plausible provisional name IF
# its local-part is EITHER a single letters-only token of >=3 letters
# ("patrick" -> "Patrick", "christian" -> "Christian" — a live 6-month
# replay showed 123 held events with zero display-name coverage anywhere
# in the inbox, the biggest single senders being plain first names like
# "christian@..." and "patrick@..."; holding them bought nothing since
# the model path has no more information than the local-part would give
# it, so the accepted cost is re-admitting initial+surname mashes like
# "ahopkins" too — both are tagged `name-from-email`, a one-line
# correction, not an invented fact) OR 2-3 letters-only dot/underscore/
# hyphen-separated tokens, EACH token >=2 letters (e.g. "thomas.wright" ->
# "Thomas Wright"). A too-short single token ("jo", "a") or a 1-letter
# token inside a multi-token split ("a.bhandhoal") is NOT a plausible name
# split — those still hold as no-name, never guessed. Digits or any other
# shape (role addresses, ids) print nothing either. Email is already
# lowercased (parse_hint's tolower()).
email_local_name() {
  local_part="${1%%@*}"
  printf '%s' "$local_part" | grep -qE '^([a-z]{3,}|[a-z]{2,}([._-][a-z]{2,}){1,2})$' || return 1
  printf '%s' "$local_part" | awk -F'[._-]' '{
    out = ""
    for (i = 1; i <= NF; i++) {
      w = $i
      out = out (i > 1 ? " " : "") toupper(substr(w, 1, 1)) substr(w, 2)
    }
    print out
  }'
}

# calendar_body_info <body-json> — ONE jq call per calendar body. Prints
# the header @tsv line (id, summary, start, end, attendee-count,
# non-self-attendee-names-csv), then zero or more "email\tdisplayName"
# lines (attendees + organizer + creator, lowercased email, any entry
# carrying both) — the body-derived name map bare-email hints fall back to
# (coordinator follow-up: "the filer must resolve identities from what is
# already on disk before holding"). Empty output means the body could not
# be parsed as calendar JSON at all.
calendar_body_info() {
  printf '%s' "$1" | jq -r '
    def to_utc_hhmm(v):
      if (v == null or v == "") then ""
      elif (v | test("Z$")) then (v | .[11:16])
      elif (v | test("[+-][0-9][0-9]:[0-9][0-9]$")) then
        (v | capture("T(?<h>[0-9]{2}):(?<m>[0-9]{2}):[0-9]{2}(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2})$")) as $c
        | (((($c.h | tonumber) * 60 + ($c.m | tonumber))
            - (if $c.sign == "+" then 1 else -1 end) * (($c.oh | tonumber) * 60 + ($c.om | tonumber)))) as $mins0
        | (($mins0 % 1440 + 1440) % 1440) as $mins
        | (($mins / 60) | floor) as $hh
        | ($mins % 60) as $mm
        | (if $hh < 10 then "0" else "" end) + ($hh | tostring) + ":" + (if $mm < 10 then "0" else "" end) + ($mm | tostring)
      else v end;
    . as $e
    | [
        ($e.id // ""),
        ($e.summary // ""),
        to_utc_hhmm($e.start.dateTime // $e.start.date // ""),
        to_utc_hhmm($e.end.dateTime // $e.end.date // ""),
        (($e.attendees // []) | length | tostring),
        (($e.attendees // []) | map(select(((.self // false) | not) and ((.resource // false) | not))) | map(.displayName // .email) | join(", "))
      ] | @tsv,
    (
      (($e.attendees // []) + [($e.organizer // {}), ($e.creator // {})])
      | map(select(((.resource // false) | not)))
      | map(select(((.email // "") != "") and ((.displayName // "") != "")))
      | .[] | [(.email | ascii_downcase), .displayName] | @tsv
    )
  ' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Self + ignore identities — <data-dir>/config/onboarding-backfill.tsv rows
# "self<TAB><identity>" and "ignore<TAB><identity>" (same shape; coordinator
# follow-up point 3 — bot/noreply senders like noreply@example.test that
# should be dropped from hints exactly like the self user, but are not the
# user). Both feed the same EXCLUDE_LIST (normalized): a hint matching
# either is dropped before resolution. Absent file -> empty list -> no
# exclusion.
# ---------------------------------------------------------------------------

EXCLUDE_LIST="${WORKTMP}/exclude-list"
: > "$EXCLUDE_LIST"
if [ -f "$CONFIG_TSV" ]; then
  while IFS="$(printf '\t')" read -r key value; do
    case "$key" in
      self|ignore) : ;;
      *) continue ;;
    esac
    [ -n "$value" ] || continue
    printf '%s\n' "$(normalize_name "$value")" >> "$EXCLUDE_LIST"
  done < "$CONFIG_TSV"
fi

# is_self_value <normalized-email-or-name> — true if it matches a
# configured self OR ignore identity (both are dropped from hints
# identically; the distinct config keys are for the human-readable config
# file only).
# EXCLUDE_BLOB — the whole (small) EXCLUDE_LIST joined into one
# comma-delimited, comma-bounded string so is_self_value can do a pure
# bash `case` substring match instead of forking grep per call (perf:
# this runs once per hint, hundreds of times per run).
EXCLUDE_BLOB=","
if [ -s "$EXCLUDE_LIST" ]; then
  exclude_content="$(<"$EXCLUDE_LIST")"
  EXCLUDE_BLOB=",${exclude_content//$'\n'/,},"
fi

is_self_value() {
  val="$1"
  [ -z "$val" ] && return 1
  case "$EXCLUDE_BLOB" in
    *",${val},"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Role/bot/group address exclusion (coordinator follow-up, final round):
# these never become a person, full stop — dropped from hints exactly
# like self/ignore, everywhere a hint is examined (batched pre-scan,
# bootstrap). The fixed local-part list, the -test/+test suffix rule, and
# the *.calendar.google.com (resource/group calendar) domain rule are ALL
# duplicated verbatim into the awk blocks below (same "no sync mechanism
# between copies" precedent as the self-list — see structured-filing.md's
# "Role/bot exclusion" section, the source of truth for this list).
# ---------------------------------------------------------------------------

ROLE_LOCAL_PARTS=",noreply,no-reply,donotreply,do-not-reply,support,dev,ask,info,hello,hi,team,admin,notifications,notification,calendar,invite,invites,mailer,mailer-daemon,postmaster,billing,sales,help,contact,news,newsletter,updates,alerts,security,bot,"

# is_role_address <email> — true (0) for a role/bot/test/group-calendar
# address that must never become a person.
is_role_address() {
  ra_email="$1"
  [ -z "$ra_email" ] && return 1
  ra_local="${ra_email%%@*}"
  ra_domain="${ra_email#*@}"
  case "$ROLE_LOCAL_PARTS" in
    *",${ra_local},"*) return 0 ;;
  esac
  case "$ra_local" in
    *-test|*+test) return 0 ;;
  esac
  case "$ra_domain" in
    *.calendar.google.com) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Identity map — snapshotted once at startup from people/*.md frontmatter
# `name` + email addresses found in the file, plus index.json values. One
# row per known slug: slug\tnorm_name\temails_csv. Newly created people
# this run are appended so later events in the same run reuse them.
# ---------------------------------------------------------------------------

IDENTITY_MAP="${WORKTMP}/identity-map"
: > "$IDENTITY_MAP"
SLUG_LIST="${WORKTMP}/slug-list"
: > "$SLUG_LIST"
# EMAIL_SLUG_BLOB — every known "email|slug" pair the identity map holds,
# comma-bounded, so identity_resolve_email is a forkless bash `case` match
# instead of an awk fork per hint (perf: the single most-called lookup in
# the main loop — every email-bearing hint calls it at least once).
# Maintained in lockstep with IDENTITY_MAP by register_identity_row below
# (the one place that appends to either).
EMAIL_SLUG_BLOB=","

# register_identity_row <slug> <norm_name> <emails_csv> — the ONLY writer
# of IDENTITY_MAP + EMAIL_SLUG_BLOB, so the two structures can never drift.
register_identity_row() {
  ri_slug="$1"
  ri_name="$2"
  ri_emails="$3"
  printf '%s\t%s\t%s\n' "$ri_slug" "$ri_name" "$ri_emails" >> "$IDENTITY_MAP"
  [ -z "$ri_emails" ] && return 0
  IFS=',' read -ra ri_email_arr <<EOF_RI
$ri_emails
EOF_RI
  for ri_e in "${ri_email_arr[@]}"; do
    [ -z "$ri_e" ] && continue
    EMAIL_SLUG_BLOB="${EMAIL_SLUG_BLOB}${ri_e}|${ri_slug},"
  done
}

if [ -d "$PEOPLE_DIR" ]; then
  for pf in "$PEOPLE_DIR"/*.md; do
    [ -e "$pf" ] || continue
    slug="$(basename "$pf" .md)"
    pfm="$(extract_frontmatter "$pf")"
    pname="$(get_field "$pfm" name)"
    norm_pname="$(normalize_name "$pname")"
    emails="$(grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' "$pf" 2>/dev/null |
      tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')"
    register_identity_row "$slug" "$norm_pname" "$emails"
    printf '%s\n' "$slug" >> "$SLUG_LIST"
  done
fi

if [ -f "$INDEX_JSON" ]; then
  jq -r '
    to_entries[]
    | [.key, ((.value | tostring) | ascii_downcase)]
    | @tsv
  ' "$INDEX_JSON" 2>/dev/null | while IFS="$(printf '\t')" read -r slug valtext; do
    [ -z "$slug" ] && continue
    idx_emails="$(printf '%s' "$valtext" |
      grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$idx_emails" ]; then
      register_identity_row "$slug" "" "$idx_emails"
    fi
  done || true
fi

# ---------------------------------------------------------------------------
# Learned identity map (coordinator follow-up, plan 31 U1): persistent
# email<->slug pairings this filer has confirmed, so a later bare-email
# hint (no display name anywhere) still resolves instead of holding.
# <data-dir>/ingestion/identities.tsv, append-only:
#   <slug>\t<email-lowercase>\t<learned-from-capture-id>
# Loaded into IDENTITY_MAP alongside people/*.md + index.json (empty
# norm_name column — email-only rows, same shape as the index.json rows
# above). A row whose slug no longer has a people/<slug>.md file (the
# person was deleted or renamed after the pairing was learned — the
# ledger itself is append-only, never rewritten) is STALE: it is skipped
# here rather than loaded, so the email falls through to normal resolution
# (hint name / body name / local-part / hold) instead of resolving to a
# dangling `[[slug]]` link that validate-store.sh would flag. Checked
# against SLUG_LIST (already fully populated by the people/*.md scan
# above) via a comma-bounded blob — same forkless `case`-match style as
# EXCLUDE_BLOB/EMAIL_SLUG_BLOB, not a grep or stat per row.
# ---------------------------------------------------------------------------

IDENTITIES_EXISTED=0
[ -f "$IDENTITIES_TSV" ] && IDENTITIES_EXISTED=1

KNOWN_SLUG_BLOB=","
if [ -s "$SLUG_LIST" ]; then
  known_slug_content="$(<"$SLUG_LIST")"
  KNOWN_SLUG_BLOB=",${known_slug_content//$'\n'/,},"
fi

# slug_has_person <slug> — true (0) iff SLUG_LIST (the people/*.md scan)
# already knows this slug.
slug_has_person() {
  case "$KNOWN_SLUG_BLOB" in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

LEARNED_SEEN="${WORKTMP}/learned-seen"
: > "$LEARNED_SEEN"
# LEARNED_BLOB — every already-known "slug<US>email" pair, comma-bounded,
# for a forkless `case` dedup check in learn_identity (perf: this is
# called once per resolved email hint, hundreds of times per run — a
# grep-per-call cost the fixture-scale corpus can absorb but the live
# corpus cannot).
LEARNED_BLOB=","

stale_count=0

if [ "$IDENTITIES_EXISTED" -eq 1 ]; then
  while IFS="$(printf '\t')" read -r li_slug li_email li_cap; do
    [ -z "$li_slug" ] && continue
    [ -z "$li_email" ] && continue
    if ! slug_has_person "$li_slug"; then
      stale_count=$((stale_count + 1))
      continue
    fi
    register_identity_row "$li_slug" "" "$li_email"
    printf '%s\t%s\n' "$li_slug" "$li_email" >> "$LEARNED_SEEN"
    LEARNED_BLOB="${LEARNED_BLOB}${li_slug}	${li_email},"
  done < "$IDENTITIES_TSV"
fi

learned_count=0

# learn_identity <slug> <email> <capture-id> — append-only, deduped by
# slug+email (a forkless `case` check against LEARNED_BLOB — LEARNED_SEEN
# the file is kept too, purely as the human-greppable/debuggable record;
# it is no longer read back). No-op in --dry-run (writes nothing, per
# --dry-run's "never creates --data-dir" contract) or when <email> is
# empty.
learn_identity() {
  li_slug="$1"
  li_email="$2"
  li_cap="$3"
  [ -z "$li_email" ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  li_norm_email="$(normalize_email "$li_email")"
  li_key="$(printf '%s\t%s' "$li_slug" "$li_norm_email")"
  case "$LEARNED_BLOB" in
    *",${li_key},"*) return 0 ;;
  esac
  printf '%s\t%s\t%s\n' "$li_slug" "$li_norm_email" "$li_cap" >> "$IDENTITIES_TSV"
  printf '%s\n' "$li_key" >> "$LEARNED_SEEN"
  LEARNED_BLOB="${LEARNED_BLOB}${li_key},"
  register_identity_row "$li_slug" "" "$li_norm_email"
  learned_count=$((learned_count + 1))
}

# slug_norm_name <slug> — the normalized `name` IDENTITY_MAP already holds
# for <slug> (from people/*.md at startup), or empty.
slug_norm_name() {
  awk -F'\t' -v s="$1" '$1 == s && $2 != "" { print $2; exit }' "$IDENTITY_MAP" 2>/dev/null
}

# first_token_conflict <lowercase-single-token-name> — true (0) when some
# person already in the identity map has this token as the FIRST word of
# their name AND their email is unknown to us (coordinator follow-up,
# final round: before minting a person from a bare local-part derivation
# like "Patrick", check whether an existing "Patrick Proulx" with no known
# email could be the same person — if so this is genuine ambiguity, not a
# safe create).
first_token_conflict() {
  awk -F'\t' -v t="$1" '
    $3 == "" && $2 != "" {
      split($2, parts, " ")
      if (parts[1] == t) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$IDENTITY_MAP" 2>/dev/null
}

# bootstrap_identities — plan 31 U1 coordinator follow-up point 3. Derives
# email<->slug pairs from the already-model-filed interactions/*.md, so a
# cold identities.tsv still resolves gmail bare-email hints against the
# people the model already filed. Never guesses: only records a pairing
# when it is forced (exactly one slug + one non-self email) or uniquely
# named (N slugs, N emails, each email's body/hint display name normalizes
# to exactly one of those slugs' names).
bootstrap_identities() {
  [ -d "$INTERACTIONS_DIR" ] || return 0
  ls "$INTERACTIONS_DIR"/*.md >/dev/null 2>&1 || return 0

  # Step A: ONE awk pass over every interactions/*.md -> "source-capture\tslugs_csv"
  # per file, in argument order (perf: replaces one 4-5 fork chain PER
  # interaction file with a single process for the whole set — the live
  # corpus has ~243 model-filed interactions to bootstrap from).
  BS_INTER_INFO="${WORKTMP}/bs-inter-info"
  awk '
    FNR == 1 { c = 0; sc = ""; ns = 0; delete seen }
    /^---$/ {
      c++
      if (c == 2) { printf "%s\t%s\n", sc, joined(); nextfile }
      next
    }
    c == 1 {
      if ($0 ~ /^source-capture:/) {
        v = $0
        sub(/^source-capture:[ \t]*/, "", v)
        gsub(/^"|"$/, "", v)
        sc = v
      }
      line = $0
      while (match(line, /\[\[[a-z0-9-]+\]\]/)) {
        slug = substr(line, RSTART + 2, RLENGTH - 4)
        if (!(slug in seen)) { seen[slug] = 1; slugs[++ns] = slug }
        line = substr(line, RSTART + RLENGTH)
      }
    }
    function joined(   i, out) {
      out = ""
      for (i = 1; i <= ns; i++) out = out (i > 1 ? "," : "") slugs[i]
      return out
    }
  ' "$INTERACTIONS_DIR"/*.md > "$BS_INTER_INFO" 2>/dev/null

  # Fan out per-source-capture slug lists (pure shell builtins — no forks).
  BS_NEEDED_RAW="${WORKTMP}/bs-needed-raw"
  : > "$BS_NEEDED_RAW"
  while IFS=$'\t' read -r sc slugs_csv; do
    [ -z "$sc" ] && continue
    [ "$sc" = "null" ] && continue
    [ -z "$slugs_csv" ] && continue
    [ -e "${INBOX_DIR}/${sc}.md" ] || continue
    printf '%s\n' "$slugs_csv" > "${WORKTMP}/bs-slugs-${sc}"
    printf '%s\n' "$sc" >> "$BS_NEEDED_RAW"
  done < "$BS_INTER_INFO"

  [ -s "$BS_NEEDED_RAW" ] || return 0
  BS_NEEDED_IDS="${WORKTMP}/bs-needed-ids"
  sort -u "$BS_NEEDED_RAW" > "$BS_NEEDED_IDS"

  # Build the referenced-event file list (only the events actually needed,
  # not the whole inbox) for the second batched awk pass.
  BS_EVT_FILES="${WORKTMP}/bs-evt-files"
  : > "$BS_EVT_FILES"
  while IFS= read -r sc; do
    [ -z "$sc" ] && continue
    printf '%s\n' "${INBOX_DIR}/${sc}.md" >> "$BS_EVT_FILES"
  done < "$BS_NEEDED_IDS"

  # Step B: ONE awk pass over every referenced source event -> type +
  # non-self email hints (email/display-name parsing and self-matching
  # folded in, using a self-list loaded once at BEGIN) — replaces the
  # per-event extract_frontmatter/get_field/extract_hints forks AND every
  # hint's separate parse_hint/is_self_value forks.
  BS_EVENT_INFO="${WORKTMP}/bs-event-info"
  awk -v selflist="$EXCLUDE_LIST" -v roleparts="$ROLE_LOCAL_PARTS" '
    BEGIN {
      while ((getline line < selflist) > 0) { if (line != "") selfmap[line] = 1 }
      close(selflist)
      nrole = split(roleparts, rolearr, ",")
      for (i = 1; i <= nrole; i++) { if (rolearr[i] != "") roleset[rolearr[i]] = 1 }
    }
    FNR == 1 {
      c = 0
      t = ""
      inh = 0
      id = FILENAME
      sub(/.*\//, "", id)
      sub(/\.md$/, "", id)
    }
    /^---$/ {
      c++
      if (c == 2) { printf "TYPE\t%s\t%s\n", id, t; nextfile }
      next
    }
    c == 1 {
      if ($0 ~ /^type:/) {
        v = $0
        sub(/^type:[ \t]*/, "", v)
        t = v
      }
      if ($0 ~ /^participant-hints:/) { inh = 1; next }
      if (inh == 1) {
        if ($0 ~ /^[ \t]+-[ \t]/) {
          v = $0
          sub(/^[ \t]+-[ \t]*/, "", v)
          gsub(/^"|"$/, "", v)
          email = ""
          if (match(v, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
            email = tolower(substr(v, RSTART, RLENGTH))
          }
          dname = ""
          if (match(v, /^[^<]*</)) {
            dname = substr(v, 1, RSTART + RLENGTH - 2)
            gsub(/[ \t]+$/, "", dname)
          }
          is_role = 0
          if (email != "") {
            split(email, ep, "@")
            if (ep[1] in roleset) { is_role = 1 }
            else if (ep[1] ~ /(-test|\+test)$/) { is_role = 1 }
            else if (ep[2] ~ /\.calendar\.google\.com$/) { is_role = 1 }
          }
          if (email != "" && !(email in selfmap) && !is_role) {
            printf "HINT\t%s\t%s\t%s\n", id, email, dname
          }
          next
        } else { inh = 0 }
      }
    }
  ' $(cat "$BS_EVT_FILES") > "$BS_EVENT_INFO" 2>/dev/null

  # Fan out per-id type/emails/names (pure shell builtins — no forks).
  while IFS=$'\t' read -r tag a b c; do
    case "$tag" in
      TYPE)
        printf '%s\n' "$b" > "${WORKTMP}/bs-type-${a}"
        ;;
      HINT)
        printf '%s\n' "$b" >> "${WORKTMP}/bs-emails-${a}"
        [ -n "$c" ] && printf '%s\t%s\n' "$b" "$c" >> "${WORKTMP}/bs-names-${a}"
        ;;
    esac
  done < "$BS_EVENT_INFO"

  # Calendar attendee/organizer/creator emails still need one jq call per
  # calendar event (JSON, not text-regexable in awk) — but only for the
  # referenced ids, and only those actually typed calendar-event.
  while IFS= read -r sc; do
    [ -z "$sc" ] && continue
    et_file="${WORKTMP}/bs-type-${sc}"
    [ -e "$et_file" ] || continue
    IFS= read -r etype < "$et_file"
    [ "$etype" = "calendar-event" ] || continue
    ebody="$(extract_body "${INBOX_DIR}/${sc}.md")"
    cal_info="$(calendar_body_info "$ebody")"
    [ -z "$cal_info" ] && continue
    printf '%s\n' "$cal_info" | tail -n +2 | while IFS=$'\t' read -r cn_email cn_name; do
      [ -z "$cn_email" ] && continue
      is_self_value "$cn_email" && continue
      is_role_address "$cn_email" && continue
      printf '%s\n' "$cn_email" >> "${WORKTMP}/bs-emails-${sc}"
      [ -n "$cn_name" ] && printf '%s\t%s\n' "$cn_email" "$cn_name" >> "${WORKTMP}/bs-names-${sc}"
    done
  done < "$BS_NEEDED_IDS"

  # Final per-interaction decision: exactly-one-slug+one-email, or
  # N-slugs+N-emails with each email's name uniquely matching one slug.
  # Also builds BS_CANDIDATES (sc\tslugs_csv\temails_csv, pure shell
  # builtins — no forks) for the constraint-propagation pass below.
  BS_CANDIDATES="${WORKTMP}/bs-candidates"
  : > "$BS_CANDIDATES"
  while IFS= read -r sc; do
    [ -z "$sc" ] && continue
    slugs_file="${WORKTMP}/bs-slugs-${sc}"
    emails_file="${WORKTMP}/bs-emails-${sc}"
    names_file="${WORKTMP}/bs-names-${sc}"
    [ -e "$slugs_file" ] || continue
    [ -e "$emails_file" ] || continue

    awk '!seen[$0]++' "$emails_file" > "${emails_file}.u" && mv "${emails_file}.u" "$emails_file"

    BS_SLUGS_LINES="${WORKTMP}/bs-slugs-lines-${sc}"
    tr ',' '\n' < "$slugs_file" > "$BS_SLUGS_LINES"

    slug_count=0
    while IFS= read -r _sl; do slug_count=$((slug_count + 1)); done < "$BS_SLUGS_LINES"
    email_count=0
    emails_csv=""
    while IFS= read -r _em; do
      [ -z "$_em" ] && continue
      email_count=$((email_count + 1))
      if [ -z "$emails_csv" ]; then emails_csv="$_em"; else emails_csv="${emails_csv},${_em}"; fi
    done < "$emails_file"

    [ "$email_count" -eq 0 ] && continue

    slugs_csv=""
    IFS= read -r slugs_csv < "$slugs_file"
    printf '%s\t%s\t%s\n' "$sc" "$slugs_csv" "$emails_csv" >> "$BS_CANDIDATES"

    if [ "$slug_count" -eq 1 ] && [ "$email_count" -eq 1 ]; then
      IFS= read -r only_slug < "$BS_SLUGS_LINES"
      IFS= read -r only_email < "$emails_file"
      learn_identity "$only_slug" "$only_email" "$sc"
    elif [ "$slug_count" -eq "$email_count" ] && [ "$slug_count" -gt 1 ]; then
      while IFS= read -r bs_email; do
        [ -z "$bs_email" ] && continue
        bs_name=""
        [ -e "$names_file" ] && bs_name="$(awk -F'\t' -v e="$bs_email" '$1 == e { print $2; exit }' "$names_file")"
        [ -z "$bs_name" ] && continue
        bs_norm_name="$(normalize_name "$bs_name")"
        match_count=0
        match_slug=""
        while IFS= read -r bs_slug; do
          [ -z "$bs_slug" ] && continue
          if [ "$(slug_norm_name "$bs_slug")" = "$bs_norm_name" ]; then
            match_count=$((match_count + 1))
            match_slug="$bs_slug"
          fi
        done < "$BS_SLUGS_LINES"
        if [ "$match_count" -eq 1 ]; then
          learn_identity "$match_slug" "$bs_email" "$sc"
        fi
      done < "$emails_file"
    fi
  done < "$BS_NEEDED_IDS"

  # Constraint propagation to a fixed point (coordinator follow-up point
  # 1): for every candidate interaction, drop any email already mapped to
  # SOME slug and any slug already mapped to SOME email (both checked
  # against the current, ever-growing IDENTITY_MAP — a single small awk
  # pass per round, not per interaction); if exactly one email and one
  # slug remain, that pairing is forced and gets learned. Repeat until a
  # round learns nothing (bounded — a real event's attendee count is
  # small, so this converges in a handful of rounds). Still never guesses
  # beyond a 1:1 residual.
  if [ -s "$BS_CANDIDATES" ]; then
    MAPPED_EMAILS="${WORKTMP}/bs-mapped-emails"
    MAPPED_SLUGS="${WORKTMP}/bs-mapped-slugs"
    NEWPAIRS="${WORKTMP}/bs-newpairs"
    round=0
    changed=1
    while [ "$changed" -eq 1 ] && [ "$round" -lt 12 ]; do
      changed=0
      round=$((round + 1))

      awk -F'\t' '$3 != "" { n = split($3, e, ","); for (i = 1; i <= n; i++) if (e[i] != "") print e[i] }' \
        "$IDENTITY_MAP" | sort -u > "$MAPPED_EMAILS"
      awk -F'\t' '$3 != "" { print $1 }' "$IDENTITY_MAP" | sort -u > "$MAPPED_SLUGS"

      awk -F'\t' -v mefile="$MAPPED_EMAILS" -v msfile="$MAPPED_SLUGS" '
        BEGIN {
          while ((getline line < mefile) > 0) if (line != "") me[line] = 1
          close(mefile)
          while ((getline line < msfile) > 0) if (line != "") ms[line] = 1
          close(msfile)
        }
        {
          sc = $1; slugs_csv = $2; emails_csv = $3
          ns = split(slugs_csv, sarr, ",")
          ne = split(emails_csv, earr, ",")
          rc = 0; rem_s = ""
          for (i = 1; i <= ns; i++) { if (!(sarr[i] in ms)) { rc++; rem_s = sarr[i] } }
          ec = 0; rem_e = ""
          for (i = 1; i <= ne; i++) { if (!(earr[i] in me)) { ec++; rem_e = earr[i] } }
          if (rc == 1 && ec == 1) print sc "\t" rem_s "\t" rem_e
        }
      ' "$BS_CANDIDATES" > "$NEWPAIRS"

      if [ -s "$NEWPAIRS" ]; then
        while IFS=$'\t' read -r p_sc p_slug p_email; do
          [ -z "$p_slug" ] && continue
          [ -z "$p_email" ] && continue
          before="$learned_count"
          learn_identity "$p_slug" "$p_email" "$p_sc"
          [ "$learned_count" -ne "$before" ] && changed=1
        done < "$NEWPAIRS"
      fi
    done
  fi
}

BOOTSTRAP_RAN=0
if [ "$DRY_RUN" -ne 1 ] && { [ "$IDENTITIES_EXISTED" -eq 0 ] || [ "$RELEARN" -eq 1 ]; }; then
  bootstrap_identities
  BOOTSTRAP_RAN=1
fi

# identity_resolve_email <email> — first matching slug, if any.
# <email> MUST already be lowercased by the caller (its sole call site's
# HINT_EMAIL already is, via parse_hint's tolower()) — no normalize_email
# fork paid per call here.
identity_resolve_email() {
  e="$1"
  [ -z "$e" ] && return 0
  case "$EMAIL_SLUG_BLOB" in
    *",${e}|"*)
      ire_rest="${EMAIL_SLUG_BLOB#*,"${e}"|}"
      printf '%s\n' "${ire_rest%%,*}"
      ;;
  esac
  return 0
}

# identity_resolve_name <name> — exact normalized-name match, one slug per
# line (may be none, may be >=2 — ambiguous).
identity_resolve_name() {
  n="$(normalize_name "$1")"
  [ -z "$n" ] && return 0
  [ -s "$IDENTITY_MAP" ] || return 0
  awk -F'\t' -v n="$n" '$2 == n && n != "" { print $1 }' "$IDENTITY_MAP"
  return 0
}

# gen_new_slug <name> — kebab-case of <name>, disambiguated against
# SLUG_LIST with -2, -3, ... suffixes.
gen_new_slug() {
  name="$1"
  base="$(kebab "$name")"
  [ -n "$base" ] || base="unnamed"
  candidate="$base"
  n=2
  while grep -qxF "$candidate" "$SLUG_LIST" 2>/dev/null; do
    candidate="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# create_person <name> <email-or-empty> <last-touch-date> — writes
# people/<slug>.md (unless --dry-run), registers the slug in the identity
# map + slug list, prints the new slug.
create_person() {
  name="$1"
  email="$2"
  last_touch="$3"
  cp_tags="${4:-}"
  cp_tags_line="[]"
  [ -n "$cp_tags" ] && cp_tags_line="[${cp_tags}]"
  slug="$(gen_new_slug "$name")"
  if [ "$DRY_RUN" -ne 1 ]; then
    # Brand-new file (gen_new_slug guarantees the name is free) — direct
    # redirection, no tmp+mv, no cat fork (perf: this is on the hot path
    # for every newly-created person, printf is a builtin).
    printf '%s\n' \
"---" \
"schema_version: 1.1.0" \
"name: ${name}" \
"org:" \
"role:" \
"location:" \
"tags: ${cp_tags_line}" \
"birthday:" \
"how-met:" \
"last-touch: ${last_touch}" \
"---" \
"" \
"## Facts" \
"" \
"_none_" \
"" \
"## Open threads" \
"" \
"_none_" \
"" \
"## Personal details" \
"" \
"_none_" \
      > "${PEOPLE_DIR}/${slug}.md"
  fi
  norm_name="$(normalize_name "$name")"
  norm_email=""
  [ -n "$email" ] && norm_email="$(normalize_email "$email")"
  register_identity_row "$slug" "$norm_name" "$norm_email"
  printf '%s\n' "$slug" >> "$SLUG_LIST"
  printf '%s' "$slug"
}

# update_last_touch <slug> <date> — bumps people/<slug>.md's last-touch
# only if <date> is newer than the current value (or the field is blank).
# Atomic tmp+mv. No-op in --dry-run.
UT_COUNTER=0

update_last_touch() {
  slug="$1"
  new_date="$2"
  pf="${PEOPLE_DIR}/${slug}.md"
  [ -f "$pf" ] || return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  # ONE awk pass: find the frontmatter's last-touch line, bump it forward
  # only if new_date is newer (or the field is blank), copy every other
  # line through unchanged — replaces the previous 2-awk-find-then-sed
  # chain (perf: this runs once per resolved person per filed event, the
  # single largest fork count in the main loop). No mktemp (a fork) —
  # WORKTMP is this process's exclusive scratch dir, so a plain counter is
  # a safe unique name.
  UT_COUNTER=$((UT_COUNTER + 1))
  tmp="${WORKTMP}/lt.${UT_COUNTER}"
  awk -v nd="$new_date" '
    BEGIN { c = 0; done = 0 }
    /^---$/ { c++; print; next }
    {
      if (c == 1 && !done && $0 ~ /^last-touch:/) {
        cur = $0
        sub(/^last-touch:[ 	]*/, "", cur)
        if (cur == "" || nd > cur) { print "last-touch: " nd } else { print }
        done = 1
        next
      }
      print
    }
  ' "$pf" > "$tmp"
  mv "$tmp" "$pf"
}

# event_date <frontmatter-text> — occurred_at's UTC date, else
# captured_at's (both are contract-guaranteed "YYYY-MM-DDTHH:MM:SSZ").
event_date() {
  fm="$1"
  occurred_at="$(get_field "$fm" occurred_at)"
  captured_at="$(get_field "$fm" captured_at)"
  src="$occurred_at"
  [ -n "$src" ] || src="$captured_at"
  printf '%s' "$src" | cut -c1-10
}

# write_interaction <capture-id> <date> <slugs-csv> <summary-text>
# <calendar-event-id-or-empty> — writes interactions/<date>-<first-slug>
# [--n].md. No-op in --dry-run.
write_interaction() {
  cap_id="$1"
  idate="$2"
  slugs_csv="$3"
  summary="$4"
  cal_id="$5"

  first_slug="${slugs_csv%%,*}"
  base="${idate}-${first_slug}"
  path="${INTERACTIONS_DIR}/${base}.md"
  n=2
  while [ -e "$path" ]; do
    path="${INTERACTIONS_DIR}/${base}--${n}.md"
    n=$((n + 1))
  done

  [ "$DRY_RUN" -eq 1 ] && return 0

  # people_links — pure bash builtins (no awk fork): split slugs_csv on
  # commas and wrap each as a quoted [[slug]] wiki-link.
  IFS=',' read -ra wi_slug_arr <<EOF_WI
$slugs_csv
EOF_WI
  people_links=""
  for wi_slug in "${wi_slug_arr[@]}"; do
    [ -z "$wi_slug" ] && continue
    if [ -z "$people_links" ]; then
      people_links="\"[[${wi_slug}]]\""
    else
      people_links="${people_links}, \"[[${wi_slug}]]\""
    fi
  done
  cal_field="null"
  [ -n "$cal_id" ] && cal_field="${cal_id}"

  # Brand-new file (the while-loop above already found a free path) —
  # direct redirection, no tmp+mv, no cat fork.
  printf '%s\n' \
"---" \
"schema_version: 1.0.0" \
"date: ${idate}" \
"people: [${people_links}]" \
"calendar-event: ${cal_field}" \
"source-capture: ${cap_id}" \
"---" \
"" \
"## Summary" \
"" \
"${summary}" \
"" \
"## Commitments" \
"" \
"_none_" \
    > "$path"
}

# ---------------------------------------------------------------------------
# 1. Eligible set — one-pass ledger partition, then a type/source/word-
#    count eligibility gate.
# ---------------------------------------------------------------------------

ID_LIST="${WORKTMP}/ids"
: > "$ID_LIST"
for f in $(ls "$INBOX_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  printf '%s\n' "${base%.md}" >> "$ID_LIST"
done

SKIP="${WORKTMP}/skip"
: > "$SKIP"
if [ -f "$FILED_LOG" ]; then
  cat "$FILED_LOG" >> "$SKIP" 2>/dev/null || true
fi
if [ -f "$TRIAGE_HELD_LOG" ]; then
  cut -f1 "$TRIAGE_HELD_LOG" >> "$SKIP" 2>/dev/null || true
fi
if [ -f "$STRUCT_HELD_LOG" ]; then
  cut -f1 "$STRUCT_HELD_LOG" >> "$SKIP" 2>/dev/null || true
fi
sort -u "$SKIP" -o "$SKIP" 2>/dev/null || true

CANDIDATE_IDS="${WORKTMP}/candidates"
if [ -s "$SKIP" ]; then
  grep -vxF -f "$SKIP" "$ID_LIST" 2>/dev/null > "$CANDIDATE_IDS" || : > "$CANDIDATE_IDS"
else
  cp "$ID_LIST" "$CANDIDATE_IDS"
fi
already_ledgered="$(( $(wc -l < "$ID_LIST" | tr -d ' ') - $(wc -l < "$CANDIDATE_IDS" | tr -d ' ') ))"

# ---------------------------------------------------------------------------
# Run-wide identity pre-scan (coordinator follow-up, final round): BEFORE
# any person is created, one batched awk pass over every candidate
# event's frontmatter — extended to drop self/ignore/role-address hints
# right here (they never become a HINT record at all) and to collect
# every "email -> display name" pairing seen anywhere in participant-
# hints — plus one jq call per referenced calendar body (unavoidable JSON
# parsing, but now done ONCE, up front, cached for reuse at summary-build
# time too) contributing its own attendee/organizer/creator name pairs.
# The two pools rank into BEST_NAME_MAP: a >=2-token display name beats a
# 1-token display name beats nothing (local-part derivation is the last
# resort, tried later, only when an email has no entry here at all). This
# is what makes every event resolve a given email to the SAME slug,
# regardless of which event happens to carry the real name — the bug this
# fixes let an early emailonly event mint "dhruv.md" from a local-part
# while a later event in the same run carried "Dhruv Mehta".
# ---------------------------------------------------------------------------

if [ -s "$CANDIDATE_IDS" ]; then
  PRESCAN_FILES="${WORKTMP}/prescan-files"
  : > "$PRESCAN_FILES"
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    printf '%s\n' "${INBOX_DIR}/${pid}.md" >> "$PRESCAN_FILES"
  done < "$CANDIDATE_IDS"

  PRESCAN_OUT="${WORKTMP}/prescan-out"
  awk -v selflist="$EXCLUDE_LIST" -v roleparts="$ROLE_LOCAL_PARTS" '
    BEGIN {
      while ((getline line < selflist) > 0) { if (line != "") selfmap[line] = 1 }
      close(selflist)
      nrole = split(roleparts, rolearr, ",")
      for (i = 1; i <= nrole; i++) { if (rolearr[i] != "") roleset[rolearr[i]] = 1 }
    }
    FNR == 1 {
      id = FILENAME
      sub(/.*\//, "", id)
      sub(/\.md$/, "", id)
      c = 0; type = ""; source = ""; capat = ""; occat = ""; inh = 0
    }
    /^---$/ {
      c++
      if (c == 2) { printf "EVT\t%s\t%s\t%s\t%s\t%s\n", id, type, source, capat, occat; nextfile }
      next
    }
    c == 1 {
      if ($0 ~ /^type:/) { v = $0; sub(/^type:[ \t]*/, "", v); type = v }
      else if ($0 ~ /^source:/) { v = $0; sub(/^source:[ \t]*/, "", v); source = v }
      else if ($0 ~ /^captured_at:/) { v = $0; sub(/^captured_at:[ \t]*/, "", v); capat = v }
      else if ($0 ~ /^occurred_at:/) { v = $0; sub(/^occurred_at:[ \t]*/, "", v); occat = v }
      else if ($0 ~ /^participant-hints:/) { inh = 1 }
      else if (inh == 1) {
        if ($0 ~ /^[ \t]+-[ \t]/) {
          v = $0
          sub(/^[ \t]+-[ \t]*/, "", v)
          gsub(/^"|"$/, "", v)
          hint = v

          email = ""
          if (match(hint, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
            email = tolower(substr(hint, RSTART, RLENGTH))
          }
          dname = ""
          if (match(hint, /^[^<]*</)) {
            dname = substr(hint, 1, RSTART + RLENGTH - 2)
            gsub(/[ \t]+$/, "", dname)
          }

          excluded = 0
          if (email != "") {
            if (email in selfmap) { excluded = 1 }
            else {
              split(email, ep, "@")
              localpart = ep[1]; domain = ep[2]
              if (localpart in roleset) { excluded = 1 }
              else if (localpart ~ /(-test|\+test)$/) { excluded = 1 }
              else if (domain ~ /\.calendar\.google\.com$/) { excluded = 1 }
            }
          } else {
            normhint = tolower(hint)
            gsub(/^[ \t]+|[ \t]+$/, "", normhint)
            gsub(/[ \t]+/, " ", normhint)
            if (normhint in selfmap) { excluded = 1 }
          }

          if (!excluded) {
            printf "HINT\t%s\t%s\n", id, hint
            if (email != "" && dname != "") { printf "NAMEPAIR\t%s\t%s\n", email, dname }
          }
          next
        } else { inh = 0 }
      }
    }
  ' $(cat "$PRESCAN_FILES") > "$PRESCAN_OUT" 2>/dev/null

  while IFS=$'\t' read -r ptag pa pb pc pd pe; do
    case "$ptag" in
      EVT)
        printf '%s\t%s\t%s\t%s\n' "$pb" "$pc" "$pd" "$pe" > "${WORKTMP}/ev-meta-${pa}"
        ;;
      HINT)
        printf '%s\n' "$pb" >> "${WORKTMP}/ev-hints-${pa}"
        ;;
    esac
  done < "$PRESCAN_OUT"

  # One jq call per referenced calendar body (same cost as before — just
  # moved earlier and cached as cal-row-<id> for reuse at summary-build
  # time, instead of being recomputed there). Its name pairs join the
  # same run-wide pool (role addresses filtered here too — jq has no
  # access to EXCLUDE_LIST/ROLE_LOCAL_PARTS, so this is the one place the
  # bash-side is_role_address is reused rather than duplicated in jq).
  CAL_NAMEPAIRS_RAW="${WORKTMP}/cal-namepairs-raw"
  : > "$CAL_NAMEPAIRS_RAW"
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    cmeta_file="${WORKTMP}/ev-meta-${pid}"
    [ -e "$cmeta_file" ] || continue
    IFS=$'\t' read -r cm_type cm_source cm_capat cm_occat < "$cmeta_file"
    [ "$cm_type" = "calendar-event" ] || continue
    cev_body="$(extract_body "${INBOX_DIR}/${pid}.md")"
    cev_info="$(calendar_body_info "$cev_body")"
    [ -z "$cev_info" ] && continue
    printf '%s\n' "$cev_info" | head -1 > "${WORKTMP}/cal-row-${pid}"
    printf '%s\n' "$cev_info" | tail -n +2 > "${WORKTMP}/cal-names-${pid}"
    while IFS=$'\t' read -r cn_email cn_name; do
      [ -z "$cn_email" ] && continue
      [ -z "$cn_name" ] && continue
      is_role_address "$cn_email" && continue
      printf '%s\t%s\n' "$cn_email" "$cn_name" >> "$CAL_NAMEPAIRS_RAW"
    done < "${WORKTMP}/cal-names-${pid}"
  done < "$CANDIDATE_IDS"

  # Rank: a >=2-token display name beats a 1-token name beats nothing.
  # Deterministic within a tier — first-seen wins (file order is
  # PRESCAN_OUT's frontmatter-scan order, then calendar-body order).
  NAMEPAIRS_ALL="${WORKTMP}/namepairs-all"
  awk -F'\t' '
    $1 == "NAMEPAIR" { print $2 "\t" $3; next }
    NF == 2 { print $1 "\t" $2 }
  ' "$PRESCAN_OUT" "$CAL_NAMEPAIRS_RAW" > "$NAMEPAIRS_ALL"

  BEST_NAME_MAP="${WORKTMP}/best-name-map"
  awk -F'\t' '
    {
      email = $1; name = $2
      if (email == "" || name == "") next
      n = split(name, toks, " ")
      score = (n >= 2) ? 2 : 1
      if (!(email in best) || score > bestscore[email]) { best[email] = name; bestscore[email] = score }
    }
    END { for (e in best) printf "%s\t%s\n", e, best[e] }
  ' "$NAMEPAIRS_ALL" > "$BEST_NAME_MAP"

  # Forkless lookup blob (pure shell builtins to build — no fork).
  BEST_NAME_BLOB=","
  while IFS=$'\t' read -r bn_email bn_name; do
    [ -z "$bn_email" ] && continue
    BEST_NAME_BLOB="${BEST_NAME_BLOB}${bn_email}|${bn_name},"
  done < "$BEST_NAME_MAP"
else
  BEST_NAME_BLOB=","
fi

# best_name_for_email <email> — the run-wide best display name for
# <email> (already lowercased by the caller), or empty if none was seen
# anywhere in the eligible set.
best_name_for_email() {
  bne_email="$1"
  case "$BEST_NAME_BLOB" in
    *",${bne_email}|"*)
      bne_rest="${BEST_NAME_BLOB#*,"${bne_email}"|}"
      printf '%s' "${bne_rest%%,*}"
      ;;
  esac
}

eligible=0
filed=0
people_new=0
held=0
skipped="$already_ledgered"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  f="${INBOX_DIR}/${id}.md"
  [ -e "$f" ] || continue

  meta_file="${WORKTMP}/ev-meta-${id}"
  [ -e "$meta_file" ] || continue
  # Precomputed by the batched pre-scan above (pure builtin read, no fork).
  IFS=$'\t' read -r type source capat occat < "$meta_file"

  body=""
  gmail_subj=""
  is_eligible=0
  if [ "$type" = "calendar-event" ]; then
    is_eligible=1
    body="$(extract_body "$f")"
  else
    case "$source" in
      gmail-in/*)
        body="$(extract_body "$f")"
        gs_info="$(gmail_subject_and_wordcount "$body")"
        gmail_subj="${gs_info%%	*}"
        wc="${gs_info##*	}"
        [ -n "$wc" ] && [ "$wc" -lt 40 ] 2>/dev/null && is_eligible=1
        ;;
    esac
  fi

  if [ "$is_eligible" -ne 1 ]; then
    skipped=$((skipped + 1))
    continue
  fi
  eligible=$((eligible + 1))

  # Calendar body was already parsed once in the run-wide pre-scan above
  # (cal-row-<id> cached there) — an unparseable calendar body means this
  # event cannot be filed at all — skip before any hint/person work.
  cal_row=""
  if [ "$type" = "calendar-event" ]; then
    cal_row_file="${WORKTMP}/cal-row-${id}"
    if [ ! -e "$cal_row_file" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    IFS= read -r cal_row < "$cal_row_file"
  fi

  hints_file="${WORKTMP}/ev-hints-${id}"
  hints=""
  [ -e "$hints_file" ] && hints="$(<"$hints_file")"

  # Unique the raw hint strings once up front (repeated attendee/hint
  # entries are common) — self-filtering and resolution then share a
  # single parse_hint call per surviving hint (perf: this loop is the hot
  # path for the 275-event budget; the original two-pass form parsed every
  # hint twice).
  UNIQ_HINTS="${WORKTMP}/uniqhints.$$"
  if [ -n "$hints" ]; then
    printf '%s\n' "$hints" | awk 'NF && !seen[$0]++' > "$UNIQ_HINTS"
  else
    : > "$UNIQ_HINTS"
  fi

  # occurred_at's UTC date, else captured_at's (both contract-guaranteed
  # "YYYY-MM-DDTHH:MM:SSZ") — pure bash parameter expansion, no fork.
  idate_src="$occat"
  [ -n "$idate_src" ] || idate_src="$capat"
  idate="${idate_src%%T*}"

  hold_reason=""
  NEW_THIS_EVENT=","
  RESOLVED_SLUGS="${WORKTMP}/resolved.$$"
  : > "$RESOLVED_SLUGS"

  while IFS= read -r hint; do
    [ -z "$hint" ] && continue
    parse_hint "$hint"
    # Self/ignore/role-address hints never reach here at all — dropped in
    # the run-wide pre-scan above, before this event's hint file was even
    # written.

    if [ -n "$HINT_EMAIL" ]; then
      slugs="$(identity_resolve_email "$HINT_EMAIL")"

      # effective_name — the hint's own display name, else the run-wide
      # BEST_NAME_MAP (a real name seen ANYWHERE in the eligible set for
      # this email — this is what makes every event resolve the same
      # email to the same slug, never a local-part guess when a real name
      # exists elsewhere), else (coordinator follow-up point 2) a name
      # derived from the email's local-part when it's a single >=3-letter
      # token or 2-3 letters-only tokens. All three go through the SAME
      # identity_resolve_name check
      # below before ever creating a person — a derived "Aaron" must
      # reuse an existing aaron.md, never shadow it with a second person.
      effective_name="$HINT_DISPLAY_NAME"
      name_is_derived=0
      if [ -z "$effective_name" ]; then
        effective_name="$(best_name_for_email "$HINT_EMAIL")"
      fi
      if [ -z "$effective_name" ]; then
        effective_name="$(email_local_name "$HINT_EMAIL" || true)"
        [ -n "$effective_name" ] && name_is_derived=1
      fi

      if [ -z "$slugs" ] && [ -n "$effective_name" ]; then
        name_slugs="$(identity_resolve_name "$effective_name")"
        name_count="$(printf '%s\n' "$name_slugs" | grep -c . || true)"
        if [ "$name_count" -ge 2 ]; then
          hold_reason="ambiguous-name:${effective_name}"
          break
        fi
        slugs="$name_slugs"
      fi

      # Single-token derived-name safety net (coordinator follow-up,
      # final round; live again after the live-corpus rebalance re-admits
      # single-token local-parts of >=3 letters): a bare local-part guess
      # like "Patrick" must not silently mint a second person when an
      # existing, email-unknown "Patrick Proulx" could plausibly be the
      # same one — hold instead of guessing.
      if [ -z "$slugs" ] && [ -n "$effective_name" ] && [ "$name_is_derived" -eq 1 ]; then
        case "$effective_name" in
          *' '*) : ;;
          *)
            if first_token_conflict "$(normalize_name "$effective_name")"; then
              hold_reason="ambiguous-name:${effective_name}"
              break
            fi
            ;;
        esac
      fi

      if [ -n "$slugs" ]; then
        matched_slug="$(printf '%s\n' "$slugs" | head -1)"
        printf '%s\n' "$matched_slug" >> "$RESOLVED_SLUGS"
        learn_identity "$matched_slug" "$HINT_EMAIL" "$id"
      elif [ -n "$effective_name" ]; then
        if [ "$name_is_derived" -eq 1 ]; then
          new_slug="$(create_person "$effective_name" "$HINT_EMAIL" "$idate" "name-from-email")"
        else
          new_slug="$(create_person "$effective_name" "$HINT_EMAIL" "$idate")"
        fi
        people_new=$((people_new + 1))
        NEW_THIS_EVENT="${NEW_THIS_EVENT}${new_slug},"
        printf '%s\n' "$new_slug" >> "$RESOLVED_SLUGS"
        learn_identity "$new_slug" "$HINT_EMAIL" "$id"
      else
        hold_reason="no-name:${HINT_EMAIL}"
        break
      fi
    else
      name_slugs="$(identity_resolve_name "$hint")"
      name_count="$(printf '%s\n' "$name_slugs" | grep -c . || true)"
      if [ "$name_count" -ge 2 ]; then
        hold_reason="ambiguous-name:${hint}"
        break
      elif [ "$name_count" -eq 1 ]; then
        printf '%s\n' "$name_slugs" >> "$RESOLVED_SLUGS"
      else
        new_slug="$(create_person "$hint" "" "$idate")"
        people_new=$((people_new + 1))
        NEW_THIS_EVENT="${NEW_THIS_EVENT}${new_slug},"
        printf '%s\n' "$new_slug" >> "$RESOLVED_SLUGS"
      fi
    fi
  done < "$UNIQ_HINTS"

  rm -f "$UNIQ_HINTS"

  if [ -n "$hold_reason" ]; then
    rm -f "$RESOLVED_SLUGS"
    held=$((held + 1))
    if [ "$DRY_RUN" -ne 1 ]; then
      printf '%s\t%s\t%s\n' "$id" "$hold_reason" "$HELD_AT" >> "$STRUCT_HELD_LOG"
    fi
    continue
  fi

  slugs_csv="$(awk '!seen[$0]++' "$RESOLVED_SLUGS" | tr '\n' ',' | sed 's/,$//')"
  rm -f "$RESOLVED_SLUGS"

  if [ -z "$slugs_csv" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  # ---- build the summary + resolve calendar-event id (cal_row was
  # already parsed once, above, before hint resolution) ----
  cal_event_id=""
  if [ "$type" = "calendar-event" ]; then
    IFS="$(printf '\t')" read -r cal_event_id cal_title cal_start cal_end cal_attn_count cal_names <<EOF_ROW
$cal_row
EOF_ROW
    # cal_start/cal_end are already UTC HH:MM (or a bare all-day date),
    # converted inside calendar_body_info's jq call — no per-event `date`
    # fork needed here anymore.
    start_fmt="$cal_start"
    end_fmt="$cal_end"
    summary="Calendar: \"${cal_title}\" with ${cal_names} (${start_fmt}\xe2\x80\x93${end_fmt} UTC, ${cal_attn_count} attendees)"
    summary="$(printf '%b' "$summary")"
  else
    subject="$gmail_subj"
    sender="$(printf '%s\n' "$hints" | head -1)"
    recipients="$(printf '%s\n' "$hints" | tail -n +2 | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
    summary="Email: \"${subject}\" \xe2\x80\x94 ${sender} \xe2\x86\x92 ${recipients}"
    summary="$(printf '%b' "$summary")"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would-file %s -> %s\n' "$id" "$slugs_csv"
  else
    write_interaction "$id" "$idate" "$slugs_csv" "$summary" "$cal_event_id"
    printf '%s\n' "$id" >> "$FILED_LOG"
    IFS=',' read -ra ut_slug_arr <<EOF_UT
$slugs_csv
EOF_UT
    for ut_s in "${ut_slug_arr[@]}"; do
      [ -z "$ut_s" ] && continue
      case "$NEW_THIS_EVENT" in
        *",${ut_s},"*) continue ;;
      esac
      update_last_touch "$ut_s" "$idate"
    done
  fi
  filed=$((filed + 1))
done < "$CANDIDATE_IDS"

if [ "$DRY_RUN" -ne 1 ] && [ "$NO_INDEX" -ne 1 ]; then
  bash "$(dirname "$0")/../../core/scripts/reindex.sh" "$STORE_DIR" --quiet
fi

if [ "$BOOTSTRAP_RAN" -eq 1 ]; then
  printf 'identities: learned=%d\n' "$learned_count"
fi

# identities: stale=<m> — count of identities.tsv rows skipped this run
# because their slug no longer has a people/<slug>.md (see the "Learned
# identity map" spec section). Printed unconditionally (0 when none) on
# its OWN line rather than folded into "identities: learned=<n>" above,
# so that line's existing exact shape — asserted verbatim by
# run-structured-tests.sh case 10b (`^identities: learned=1$`) — stays
# untouched.
printf 'identities: stale=%d\n' "$stale_count"

printf 'file-structured: eligible=%d filed=%d people_new=%d held=%d skipped=%d\n' \
  "$eligible" "$filed" "$people_new" "$held" "$skipped"
