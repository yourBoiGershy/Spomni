#!/usr/bin/env bash
# derive-participation.sh — derive per-person participation flags
# (user_engaged, group_linked) from preserved raw capture events, as
# ephemeral input to onboarding tier suggestions (plan 24 unit 7 / D1: this
# is a read pass over already-preserved data, never a store write; the
# resulting flags are never persisted to any file).
#
# Usage:
#   derive-participation.sh <store-dir> <stats-json-path> <window-start-iso> <config-path>
#
# <config-path> is <data-dir>/config/onboarding-backfill.tsv (see
# packages/core/contracts/onboarding-backfill.md). Only the repeatable
# `self` key matters here; `window_months` rows are validated (fail-closed
# posture applies to the whole file) but otherwise ignored — the caller
# already resolved the window into <window-start-iso>.
#
# For every slug in <stats-json-path>'s "people" map, over that person's
# stats.json interactions dated >= <window-start-iso>, this script follows
# interactions/<id>.md's `source-capture` field back to the inbox/ capture
# event, then to the preserved raw payload behind it (archive/raw/<id>.json,
# or — for the beeper-in lane, which never writes to archive/raw — the raw
# JSON embedded verbatim as the inbox capture event's own body), to derive:
#
#   user_engaged  = 1 if any linked raw event is authored by a `self`
#                   identity (gmail: top-level .sender address on the
#                   archived message object; beeper: any message in the
#                   archived/embedded .messages[] with isSender == true).
#   group_linked  = 1 if any linked capture event's own inbox/ frontmatter
#                   carries >= 3 participant-hints entries.
#
# Output: deterministic TSV to stdout, sorted by slug:
#   slug<TAB>user_engaged<TAB>group_linked
# Every slug present in stats.json's "people" map gets exactly one row
# (defaulting to 0/0 when it has no qualifying signal in-window). Nothing
# else goes to stdout; diagnostics go to stderr.
#
# Read-only: this script never writes to <store-dir> or the data dir.
#
# Lossy-tolerant: a missing interactions/<id>.md, a source-capture that is
# null/absent, a missing inbox/<id>.md, or a missing/unreadable raw payload
# is skipped with a stderr warning — never aborts the run. The one thing
# that DOES fail closed is the config file: zero resolved `self` entries
# (file absent, or present with no `self` rows), or any malformed row
# (unknown key, not key<TAB>value, non-integer/`< 1` window_months) —
# packages/core/contracts/onboarding-backfill.md's fail-closed posture.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if [ $# -ne 4 ]; then
  echo "usage: derive-participation.sh <store-dir> <stats-json-path> <window-start-iso> <config-path>" >&2
  exit 1
fi

STORE_DIR="$1"
STATS_JSON="$2"
WINDOW_START="$3"
CONFIG_PATH="$4"

if ! command -v jq >/dev/null 2>&1; then
  echo "derive-participation.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ ! -f "$STATS_JSON" ]; then
  echo "derive-participation.sh: ${STATS_JSON}: no such stats.json file" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Config parsing (fail-closed): key<TAB>value rows, blank/# lines ignored,
# `self` repeatable, `window_months` validated-but-unused, unknown key or a
# non key<TAB>value row rejects the whole file.
# ---------------------------------------------------------------------------
SELF_LIST="$(mktemp)"
trap 'rm -f "$SELF_LIST"' EXIT

if [ -f "$CONFIG_PATH" ]; then
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac

    tab="$(printf '\t')"
    key="${line%%"$tab"*}"
    value="${line#*"$tab"}"
    if [ "$key" = "$line" ]; then
      echo "derive-participation.sh: ${CONFIG_PATH}:${lineno}: malformed row (expected key<TAB>value): ${line}" >&2
      exit 1
    fi

    case "$key" in
      self)
        [ -n "$value" ] && printf '%s\n' "$value" >> "$SELF_LIST"
        ;;
      window_months)
        case "$value" in
          ''|*[!0-9]*)
            echo "derive-participation.sh: ${CONFIG_PATH}:${lineno}: window_months must be a positive integer, got '${value}'" >&2
            exit 1
            ;;
        esac
        if [ "$value" -lt 1 ]; then
          echo "derive-participation.sh: ${CONFIG_PATH}:${lineno}: window_months must be >= 1, got '${value}'" >&2
          exit 1
        fi
        ;;
      *)
        echo "derive-participation.sh: ${CONFIG_PATH}:${lineno}: unknown key '${key}'" >&2
        exit 1
        ;;
    esac
  done < "$CONFIG_PATH"
fi

if [ ! -s "$SELF_LIST" ]; then
  echo "derive-participation.sh: no 'self' identities resolved from ${CONFIG_PATH} — add one or more 'self<TAB><your-email-or-handle>' rows before running onboarding tier seeding" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# self_match <address> — 1 if <address> (case-insensitive, and also matching
# the bare email inside a "Name <email>" form) equals any configured self
# identity, else 1 status via return code.
# ---------------------------------------------------------------------------
self_match() {
  addr_l="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  bracket_l="$(printf '%s' "$addr_l" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
  while IFS= read -r self; do
    [ -z "$self" ] && continue
    self_l="$(printf '%s' "$self" | tr '[:upper:]' '[:lower:]')"
    if [ "$addr_l" = "$self_l" ]; then
      return 0
    fi
    if [ -n "$bracket_l" ] && [ "$bracket_l" = "$self_l" ]; then
      return 0
    fi
  done < "$SELF_LIST"
  return 1
}

# ---------------------------------------------------------------------------
# extract_body <file> — everything after the frontmatter's closing '---'
# line (the second '---' seen), byte-for-byte as written by
# normalize-capture.sh.
# ---------------------------------------------------------------------------
extract_body() {
  awk '
    /^---$/ { n++; next }
    n >= 2 { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# get_source_capture <interaction-id> — prints the interaction's
# source-capture id, or nothing if the file is missing/absent/null.
# ---------------------------------------------------------------------------
get_source_capture() {
  interaction_file="${STORE_DIR}/interactions/$1.md"
  if [ ! -f "$interaction_file" ]; then
    return
  fi
  awk '
    /^source-capture:[ \t]*/ {
      v = $0
      sub(/^source-capture:[ \t]*/, "", v)
      gsub(/^"|"$/, "", v)
      if (v != "null" && v != "") print v
      exit
    }
  ' "$interaction_file"
}

# ---------------------------------------------------------------------------
# capture_flags <capture-id> — prints "engaged<TAB>group" (0/1 each) for a
# capture event, memoized on disk (same capture id can back many
# interactions/many people). Missing inbox file or unreadable raw payload:
# stderr warning, treated as 0/0 for that capture — never aborts.
# ---------------------------------------------------------------------------
CACHE_DIR="$(mktemp -d)"
trap 'rm -f "$SELF_LIST"; rm -rf "$CACHE_DIR"' EXIT

capture_flags() {
  capture_id="$1"
  cache_file="${CACHE_DIR}/${capture_id}"
  if [ -f "$cache_file" ]; then
    cat "$cache_file"
    return
  fi

  inbox_file="${STORE_DIR}/inbox/${capture_id}.md"
  if [ ! -f "$inbox_file" ]; then
    echo "derive-participation.sh: missing inbox capture event '${capture_id}' — skipping" >&2
    printf '0\t0\n' | tee "$cache_file"
    return
  fi

  # Extract type / source / participant-hints count from the frontmatter.
  fm="$(awk '
    BEGIN { in_hints = 0; hints = 0; type = ""; source = "" }
    /^---$/ { fmcount++; if (fmcount == 2) exit; next }
    {
      if ($0 ~ /^participant-hints:/) { in_hints = 1; next }
      if (in_hints == 1) {
        if ($0 ~ /^[ \t]+-[ \t]/) { hints++; next }
        else { in_hints = 0 }
      }
      if ($0 ~ /^type:[ \t]*/) { t = $0; sub(/^type:[ \t]*/, "", t); type = t }
      if ($0 ~ /^source:[ \t]*/) { s = $0; sub(/^source:[ \t]*/, "", s); source = s }
    }
    END { printf "%s\t%s\t%d\n", type, source, hints }
  ' "$inbox_file")"

  fm_source="$(printf '%s' "$fm" | cut -f2)"
  fm_hints="$(printf '%s' "$fm" | cut -f3)"

  group=0
  if [ "$fm_hints" -ge 3 ] 2>/dev/null; then
    group=1
  fi

  engaged=0
  raw_file="${STORE_DIR}/archive/raw/${capture_id}.json"

  case "$fm_source" in
    gmail-in*)
      if [ -f "$raw_file" ]; then
        sender="$(jq -r '.sender // empty' "$raw_file" 2>/dev/null)"
        if [ -n "$sender" ] && self_match "$sender"; then
          engaged=1
        fi
      else
        echo "derive-participation.sh: missing archive/raw payload for '${capture_id}' (gmail) — skipping engagement signal" >&2
      fi
      ;;
    beeper-in*)
      payload=""
      if [ -f "$raw_file" ]; then
        payload="$(cat "$raw_file")"
      else
        payload="$(extract_body "$inbox_file")"
      fi
      if [ -n "$payload" ]; then
        self_msg_count="$(printf '%s' "$payload" | jq -r '[.messages[]? | select(.isSender == true)] | length' 2>/dev/null || echo "")"
        if [ -n "$self_msg_count" ] && [ "$self_msg_count" -gt 0 ] 2>/dev/null; then
          engaged=1
        fi
      else
        echo "derive-participation.sh: unreadable raw payload for '${capture_id}' (beeper) — skipping engagement signal" >&2
      fi
      ;;
    *)
      # No authored-message signal on this lane (e.g. calendar-in) —
      # engagement stays 0; group_linked is still derived above.
      ;;
  esac

  printf '%s\t%s\n' "$engaged" "$group" | tee "$cache_file"
}

# ---------------------------------------------------------------------------
# Main pass: seed every slug at 0/0, then fold in signals from each
# in-window interaction.
# ---------------------------------------------------------------------------
ACC="$(mktemp)"
trap 'rm -f "$SELF_LIST" "$ACC"; rm -rf "$CACHE_DIR"' EXIT

jq -r '.people | keys[] | . + "\t0\t0"' "$STATS_JSON" > "$ACC"

jq -r --arg ws "$WINDOW_START" '
  .people | to_entries[] | .key as $slug
  | .value.interactions[]? | select(.date >= $ws)
  | "\($slug)\t\(.id)"
' "$STATS_JSON" | while IFS="$(printf '\t')" read -r slug interaction_id; do
  [ -z "$slug" ] && continue

  source_capture="$(get_source_capture "$interaction_id")"
  if [ -z "$source_capture" ]; then
    echo "derive-participation.sh: interaction '${interaction_id}' has no source-capture — skipping" >&2
    continue
  fi

  flags="$(capture_flags "$source_capture")"
  engaged="$(printf '%s' "$flags" | cut -f1)"
  group="$(printf '%s' "$flags" | cut -f2)"

  printf '%s\t%s\t%s\n' "$slug" "$engaged" "$group" >> "$ACC"
done

awk -F'\t' '
  {
    slug = $1
    seen[slug] = 1
    if (!(slug in me) || $2 + 0 > me[slug]) me[slug] = $2 + 0
    if (!(slug in mg) || $3 + 0 > mg[slug]) mg[slug] = $3 + 0
  }
  END {
    for (s in seen) print s "\t" me[s] "\t" mg[s]
  }
' "$ACC" | sort
