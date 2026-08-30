#!/usr/bin/env bash
# shard-filing-batch.sh — deterministic person-sharded pre-pass over the
# eligible filing batch, per packages/ingestion/specs/parallel-filing.md D1.
# No model in the loop: connected components over participant-hints predict
# which events would touch the same person(s), so a wave of parallel debrief
# shard-mode workers (see the spec's D2/D3) can never write the same person
# file.
#
# Usage:
#   shard-filing-batch.sh <store-dir> [--data-dir <dir>] [--max-shards <n>]
#                          [--out-dir <dir>]
#
# <store-dir>/inbox/*.md is scanned (never inbox/quarantine/). The eligible
# set is events whose id is in neither <data-dir>/debrief-filed.log nor
# <data-dir>/triage-held.log — the same batch-mode selection the debrief
# skill uses. --data-dir defaults to "data/ingestion" (triage-inbox.sh's
# convention). --max-shards defaults to 8, hard-capped at 12 (the
# mutating-worker concurrency cap is 15; headroom stays reserved for the
# orchestrator's other workers). --out-dir defaults to
# "<data-dir>/shards".
#
# Per eligible event, each participant-hints entry is resolved to a "key"
# against an identity map snapshotted once at startup from index.json/
# people/*.md frontmatter `name` + email addresses (identity fields only —
# never an unanchored substring match against prose body text): an exact
# email or exact normalized-name match resolves to that person's slug (a
# known person); otherwise the hint is a "new" person, keyed by its
# normalized email. A hint that also carries a display name (the
# "Name <email>" form) ALWAYS additionally contributes a normalized-name
# key, so two differently-addressed hints for one not-yet-a-person contact
# still collide on the shared name; a bare name with no email resolves the
# same way against that same normalized-name key. A hint matching more
# than one candidate contributes ALL matched keys (ambiguity is merged,
# never guessed). Events sharing any key land in the same connected
# component. Zero-hint events cannot be bounded to any person and are
# excluded from the wave — written to leftover.ids for a serial post-wave
# pass instead.
#
# Components in excess of --max-shards are bin-packed: sorted by event
# count descending (ties by first-appearance order), then assigned
# round-robin into the shards actually used (min(components, max-shards)).
#
# Artifacts, all under --out-dir (stale shard-*.ids/leftover.ids from a
# prior run are cleared first):
#   <out-dir>/shard-<k>.ids   — one capture-id per line, oldest-first by
#                               captured_at, ties by filename; k = 1..shards
#   <out-dir>/leftover.ids    — the zero-hint events, same ordering
# Ends with exactly one summary line to stdout, every terminal state
# covered (including eligible=0), silence impossible:
#   shard: eligible=<n> components=<c> shards=<s> leftover=<z>
#
# Deterministic and byte-stable: running twice against an unchanged store
# and ledgers produces byte-identical artifacts and summary line. Read-only
# against <store-dir> — writes nothing outside --out-dir.
#
# Exit 0 on a completed pass (leftover=eligible is a valid outcome);
# non-zero only on usage/IO errors (missing store-dir, missing inbox/,
# missing jq). Portable to bash 3.2 (macOS default): no associative
# arrays, no mapfile, no ${var,,}.

set -eu

usage() {
  echo "usage: shard-filing-batch.sh <store-dir> [--data-dir <dir>] [--max-shards <n>] [--out-dir <dir>]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
shift

DATA_DIR="data/ingestion"
MAX_SHARDS=8
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "shard-filing-batch.sh: --data-dir requires an argument" >&2
        exit 1
      fi
      DATA_DIR="$2"
      shift 2
      ;;
    --max-shards)
      if [ $# -lt 2 ]; then
        echo "shard-filing-batch.sh: --max-shards requires an argument" >&2
        exit 1
      fi
      MAX_SHARDS="$2"
      shift 2
      ;;
    --out-dir)
      if [ $# -lt 2 ]; then
        echo "shard-filing-batch.sh: --out-dir requires an argument" >&2
        exit 1
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "shard-filing-batch.sh: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

case "$MAX_SHARDS" in
  ''|*[!0-9]*)
    echo "shard-filing-batch.sh: --max-shards must be a positive integer" >&2
    exit 1
    ;;
esac
if [ "$MAX_SHARDS" -lt 1 ]; then
  MAX_SHARDS=1
elif [ "$MAX_SHARDS" -gt 12 ]; then
  MAX_SHARDS=12
fi

[ -n "$OUT_DIR" ] || OUT_DIR="${DATA_DIR}/shards"

if ! command -v jq >/dev/null 2>&1; then
  echo "shard-filing-batch.sh: jq is required but not found on PATH" >&2
  exit 1
fi

INBOX_DIR="${STORE_DIR}/inbox"
if [ ! -d "$INBOX_DIR" ]; then
  echo "shard-filing-batch.sh: ${INBOX_DIR}: no such inbox directory" >&2
  exit 1
fi

FILED_LOG="${DATA_DIR}/debrief-filed.log"
HELD_LOG="${DATA_DIR}/triage-held.log"
INDEX_JSON="${STORE_DIR}/index.json"
PEOPLE_DIR="${STORE_DIR}/people"

WORKTMP="$(mktemp -d "${TMPDIR:-/tmp}/shard-filing.XXXXXX")"
cleanup_worktmp() {
  rm -rf "$WORKTMP"
}
trap cleanup_worktmp EXIT

# ---------------------------------------------------------------------------
# Frontmatter helpers — same shape as triage-inbox.sh's (duplicated per that
# script's own "no sync mechanism between copies" precedent).
# ---------------------------------------------------------------------------

extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
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

# parse_hint <hint> — sets HINT_EMAIL (first email-looking substring, may be
# empty) and HINT_DISPLAY_NAME (the text before "<...>", trimmed; empty if
# the hint has no angle-bracket form). Same regex as triage-inbox.sh's
# sender_known.
parse_hint() {
  hint="$1"
  HINT_EMAIL="$(printf '%s' "$hint" | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1)"
  HINT_DISPLAY_NAME="$(printf '%s' "$hint" | sed -n 's/^\([^<]*\)<.*/\1/p' | sed 's/[[:space:]]*$//')"
}

normalize_email() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Note: [[:space:]] (POSIX class), not [ \t] — BSD/macOS sed has no \t
# escape inside a bracket expression, so [ \t] matches the three literal
# characters space, backslash, and 't', silently eating a leading/trailing
# "t"/"T" from names like "Team" -> "eam" instead of trimming whitespace.
normalize_name() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g'
}

# ---------------------------------------------------------------------------
# Identity map — snapshotted ONCE at startup (not per hint): one row per
# known slug, `slug\tnorm_name\tnorm_email1,norm_email2,...`. Resolution
# below is restricted to identity fields only — frontmatter `name` (exact
# normalized match) and email addresses (exact match against email-shaped
# tokens extracted from the person file / index.json value) — never an
# unanchored substring match against prose body text, which is what let a
# short hint (a chat title, a bare first name) over-merge the whole store
# into one component. This mirrors the debrief skill's own §3 matching
# (name / alias / contact-detail identity fields only).
# ---------------------------------------------------------------------------

IDENTITY_MAP="${WORKTMP}/identity-map"
: > "$IDENTITY_MAP"

if [ -d "$PEOPLE_DIR" ]; then
  for pf in "$PEOPLE_DIR"/*.md; do
    [ -e "$pf" ] || continue
    slug="$(basename "$pf" .md)"
    pfm="$(extract_frontmatter "$pf")"
    pname="$(get_field "$pfm" name)"
    norm_pname="$(normalize_name "$pname")"
    emails="$(grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' "$pf" 2>/dev/null |
      tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')"
    printf '%s\t%s\t%s\n' "$slug" "$norm_pname" "$emails" >> "$IDENTITY_MAP"
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
      printf '%s\t\t%s\n' "$slug" "$idx_emails" >> "$IDENTITY_MAP"
    fi
  done || true
fi

# identity_resolve_email <email> — exact match against any known slug's
# email list; prints one matching slug per line (may be none).
identity_resolve_email() {
  e="$(normalize_email "$1")"
  [ -z "$e" ] && return 0
  [ -s "$IDENTITY_MAP" ] || return 0
  awk -F'\t' -v e="$e" '
    {
      n = split($3, arr, ",")
      for (i = 1; i <= n; i++) { if (arr[i] == e) { print $1; break } }
    }
  ' "$IDENTITY_MAP"
  return 0
}

# identity_resolve_name <name> — exact normalized match against a known
# slug's frontmatter `name`; prints one matching slug per line (may be
# none, may be more than one if two people share a display name).
identity_resolve_name() {
  n="$(normalize_name "$1")"
  [ -z "$n" ] && return 0
  [ -s "$IDENTITY_MAP" ] || return 0
  awk -F'\t' -v n="$n" '$2 == n { print $1 }' "$IDENTITY_MAP"
  return 0
}

# ---------------------------------------------------------------------------
# 1. Eligible set — one-pass ledger partition (D4a style): a single
#    grep -vxF -f pass against a combined skip file, not per-event greps.
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
if [ -f "$HELD_LOG" ]; then
  cut -f1 "$HELD_LOG" >> "$SKIP" 2>/dev/null || true
fi
sort -u "$SKIP" -o "$SKIP" 2>/dev/null || true

ELIGIBLE_IDS="${WORKTMP}/eligible"
if [ -s "$SKIP" ]; then
  grep -vxF -f "$SKIP" "$ID_LIST" 2>/dev/null > "$ELIGIBLE_IDS" || true
else
  cp "$ID_LIST" "$ELIGIBLE_IDS"
fi

eligible="$(wc -l < "$ELIGIBLE_IDS" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 2. Canonical chronological order (captured_at, tie by filename/id) — used
#    both for artifact ordering and for deterministic first-appearance
#    component numbering.
# ---------------------------------------------------------------------------

EVENT_ORDER="${WORKTMP}/event-order"
: > "$EVENT_ORDER"
HINTS_RAW="${WORKTMP}/hints-raw"
: > "$HINTS_RAW"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  f="${INBOX_DIR}/${id}.md"
  [ -e "$f" ] || continue
  fm="$(extract_frontmatter "$f")"
  captured_at="$(get_field "$fm" captured_at)"
  printf '%s\t%s\n' "$captured_at" "$id" >> "$EVENT_ORDER"
  hints="$(extract_hints "$fm")"
  [ -z "$hints" ] && continue
  while IFS= read -r hint; do
    [ -z "$hint" ] && continue
    printf '%s\t%s\n' "$id" "$hint" >> "$HINTS_RAW"
  done <<EOF_H
$hints
EOF_H
done < "$ELIGIBLE_IDS"

sort -t "$(printf '\t')" -k1,1 -k2,2 "$EVENT_ORDER" -o "$EVENT_ORDER"

# ---------------------------------------------------------------------------
# 3. Hint -> key resolution, two passes: email-bearing hints first (they
#    also seed the in-batch name->key map for new-person ambiguity
#    resolution), then bare-name hints.
# ---------------------------------------------------------------------------

EMAIL_HINTS="${WORKTMP}/email-hints"
NAME_ONLY_HINTS="${WORKTMP}/name-hints"
: > "$EMAIL_HINTS"
: > "$NAME_ONLY_HINTS"

while IFS="$(printf '\t')" read -r id hint; do
  [ -z "$id" ] && continue
  parse_hint "$hint"
  if [ -n "$HINT_EMAIL" ]; then
    printf '%s\t%s\t%s\n' "$id" "$HINT_EMAIL" "$HINT_DISPLAY_NAME" >> "$EMAIL_HINTS"
  else
    printf '%s\t%s\n' "$id" "$hint" >> "$NAME_ONLY_HINTS"
  fi
done < "$HINTS_RAW"

IDKEYS="${WORKTMP}/idkeys"
: > "$IDKEYS"

# Pass 1: email-bearing hints. Each contributes the email-derived key (a
# resolved slug if the email is known, else a synthetic new:<email> key)
# and, if the hint also carried a display name, ALWAYS additionally
# contributes the normalized-display-name key `new:<normalized-name>` —
# so two email-hints for the same not-yet-a-person contact under two
# different addresses still collide and merge on the shared name, rather
# than sharding into two components that would both try to create the
# same person file (F1).
while IFS="$(printf '\t')" read -r id email dname; do
  [ -z "$id" ] && continue
  norm_email="$(normalize_email "$email")"
  slugs="$(identity_resolve_email "$email")"
  if [ -z "$slugs" ] && [ -n "$dname" ]; then
    slugs="$(identity_resolve_name "$dname")"
  fi
  if [ -n "$slugs" ]; then
    printf '%s\n' "$slugs" | sort -u | while IFS= read -r s; do
      [ -z "$s" ] && continue
      printf '%s\tslug:%s\n' "$id" "$s" >> "$IDKEYS"
    done
  else
    newkey="new:${norm_email}"
    printf '%s\t%s\n' "$id" "$newkey" >> "$IDKEYS"
  fi
  if [ -n "$dname" ]; then
    norm_name="$(normalize_name "$dname")"
    printf '%s\tnew:%s\n' "$id" "$norm_name" >> "$IDKEYS"
  fi
done < "$EMAIL_HINTS"

# Pass 2: bare-name hints (no email at all). Store lookup first (exact
# normalized name match, may return more than one slug — ambiguity-merge);
# otherwise the same normalized-name key any pass-1 hint with this same
# display name already contributed (or will contribute independent of
# processing order — union-find doesn't care which side unions first).
while IFS="$(printf '\t')" read -r id hint; do
  [ -z "$id" ] && continue
  parse_hint "$hint"
  if [ -n "$HINT_DISPLAY_NAME" ]; then
    name_for_lookup="$HINT_DISPLAY_NAME"
  else
    name_for_lookup="$hint"
  fi
  slugs="$(identity_resolve_name "$name_for_lookup")"
  if [ -n "$slugs" ]; then
    printf '%s\n' "$slugs" | sort -u | while IFS= read -r s; do
      [ -z "$s" ] && continue
      printf '%s\tslug:%s\n' "$id" "$s" >> "$IDKEYS"
    done
    continue
  fi
  norm_name="$(normalize_name "$name_for_lookup")"
  newkey="new:${norm_name}"
  printf '%s\t%s\n' "$id" "$newkey" >> "$IDKEYS"
done < "$NAME_ONLY_HINTS"

# ---------------------------------------------------------------------------
# 4. Connected components — union-find over (id, key) pairs in awk.
# ---------------------------------------------------------------------------

ROOT_MAP="${WORKTMP}/root-map"
awk -F'\t' '
  function froot(x,   r, nx) {
    r = x
    while (parent[r] != r) r = parent[r]
    while (parent[x] != r) { nx = parent[x]; parent[x] = r; x = nx }
    return r
  }
  {
    id = $1; key = $2
    if (!(id in parent)) { parent[id] = id; idlist[++nid] = id }
    kk = "K:" key
    if (!(kk in parent)) parent[kk] = kk
    ra = froot(id)
    rb = froot(kk)
    if (ra != rb) parent[ra] = rb
  }
  END {
    for (i = 1; i <= nid; i++) {
      id = idlist[i]
      print id "\t" froot(id)
    }
  }
' "$IDKEYS" > "$ROOT_MAP"

# Deterministic component numbering, in EVENT_ORDER's first-appearance order.
ID_COMPONENT="${WORKTMP}/id-component"
awk -F'\t' '
  NR == FNR { root[$1] = $2; next }
  {
    id = $2
    if (id in root) {
      r = root[id]
      if (!(r in compnum)) { c++; compnum[r] = c }
      print id "\t" compnum[r]
    }
  }
' "$ROOT_MAP" "$EVENT_ORDER" > "$ID_COMPONENT"

components="$(cut -f2 "$ID_COMPONENT" | sort -un | tail -1)"
[ -z "$components" ] && components=0

# ---------------------------------------------------------------------------
# 5. Leftover — eligible ids with no key at all (zero participant-hints).
# ---------------------------------------------------------------------------

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/shard-*.ids "$OUT_DIR"/leftover.ids 2>/dev/null || true

awk -F'\t' '
  NR == FNR { has[$1] = 1; next }
  { if (!($2 in has)) print $2 }
' "$ID_COMPONENT" "$EVENT_ORDER" > "$OUT_DIR/leftover.ids"

leftover="$(wc -l < "$OUT_DIR/leftover.ids" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 6. Bin-packing: components sorted by event count desc (ties by
#    first-appearance component number asc), round-robin into
#    min(components, MAX_SHARDS) shards.
# ---------------------------------------------------------------------------

if [ "$components" -eq 0 ]; then
  shards=0
else
  if [ "$components" -lt "$MAX_SHARDS" ]; then
    shards="$components"
  else
    shards="$MAX_SHARDS"
  fi

  COMP_COUNTS="${WORKTMP}/comp-counts"
  cut -f2 "$ID_COMPONENT" | sort -n | uniq -c |
    awk '{ print $2 "\t" $1 }' > "$COMP_COUNTS"

  COMP_ORDER="${WORKTMP}/comp-order"
  sort -t "$(printf '\t')" -k2,2nr -k1,1n "$COMP_COUNTS" > "$COMP_ORDER"

  COMP_SHARD="${WORKTMP}/comp-shard"
  awk -F'\t' -v shards="$shards" '
    { comp = $1; shard = (NR - 1) % shards + 1; print comp "\t" shard }
  ' "$COMP_ORDER" > "$COMP_SHARD"

  ID_SHARD="${WORKTMP}/id-shard"
  awk -F'\t' '
    NR == FNR { shard[$1] = $2; next }
    { print $1 "\t" shard[$2] }
  ' "$COMP_SHARD" "$ID_COMPONENT" > "$ID_SHARD"

  k=1
  while [ "$k" -le "$shards" ]; do
    awk -F'\t' -v k="$k" '$2 == k { print $1 }' "$ID_SHARD" > "$OUT_DIR/shard-${k}.ids"
    k=$((k + 1))
  done
fi

printf 'shard: eligible=%d components=%d shards=%d leftover=%d\n' \
  "$eligible" "$components" "$shards" "$leftover"

exit 0
