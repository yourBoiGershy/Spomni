#!/usr/bin/env bash
# derive-user-model.sh — write the user-model.md DRAFT from the corpus.
# Model of record: packages/ingestion/specs/user-model-derive.md (read it
# before touching this script). Template: packages/core/templates/user-model.md.
# Contract: packages/core/contracts/user-model.md.
#
# Usage:
#   derive-user-model.sh <store> [--today YYYY-MM-DD] [--redraft]
#                         [--similarity-file <json>]
#
# Trailing 90-day window ending at <today> (default: today, UTC). Per axis
# — business, friends, family, community, transactional, the fixed
# five-axis set — computes two independent shares over in-window
# interactions: share of interactions and share of calendar-typed
# ("meeting") interactions, both attributed via a single per-person axis
# assignment (never split across axes for the same person):
#
#   1. If people/<slug>.md has a `kind` (and it isn't `unknown`), map it:
#        friend->friends  family->family  collaborator->business
#        professional->business  community->community
#        transactional->transactional  scheduling->transactional
#        unsolicited->transactional
#   2. Else, in order: a calendar meeting with >=2 attendees (self
#      excluded) in-window -> business; an in-window interaction whose
#      source-capture is a personal Beeper channel (`beeper-in-whatsapp`
#      or `beeper-in-matrix` specifically, not `beeper-in-linkedin`) ->
#      friends; a `family` tag on the person -> family; else unassigned.
#
# Weight per axis = round(interaction share, 2). Zero in-window evidence
# on an axis (no interactions and no meetings) renders as
# "<axis>: 0.00 — no evidence in window". The five axis shares plus
# `unassigned` always sum to 1.00 (modulo rounding) — the denominator is
# the total count of in-window (person, interaction) pairs, so no
# interaction is silently dropped even when a group interaction links
# people who resolve to different axes.
#
# Writes <store>/user-model.md from packages/core/templates/user-model.md
# with status: draft, provenance: observed-from-behavior, derived_at:
# <today>, confirmed_at: null, revision: 0. `## Investment mix` is
# initialized from the revealed interaction-share weights. `## Protected
# time` / `## Season` are left with only the template's guidance-comment
# placeholders. `## Revealed vs stated` carries the
# "revealed (observed-from-behavior):" block (contracts/user-model.md's
# heading text, reproduced verbatim) with the five axis shares, the
# `unassigned` line, each axis's meeting share reported alongside (never
# blended into the weight), and — only when --similarity-file is given —
# one verbatim `embedding-similarity: ...` line built from that file's
# {business, friends, family, community, transactional, model} JSON.
#
# Refuses to overwrite a `status: confirmed` user-model.md: exit 2, reason
# on stderr, file left byte-identical — unless --redraft is passed, in
# which case a side-by-side user-model.draft.md is written instead and the
# confirmed file is never touched. derive-user-model.sh never writes
# `status: confirmed` under any flag combination. Atomic write (temp file
# + mv within <store>).
#
# Read-only over <store> otherwise: people/, interactions/, stats.json
# (recomputed into a scratch dir via packages/core/scripts/build-stats.sh
# when absent/stale, same as derive-evidence.sh — <store>/stats.json is
# never written by this script). Never opens inbox/ or archive/.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "derive-user-model.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "usage: derive-user-model.sh <store> [--today YYYY-MM-DD] [--redraft] [--similarity-file <json>]" >&2
  exit 1
fi

STORE="$1"
shift

TODAY=""
REDRAFT=0
SIMILARITY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    --redraft)
      REDRAFT=1
      shift
      ;;
    --similarity-file)
      SIMILARITY_FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "derive-user-model.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$STORE" ]; then
  echo "derive-user-model.sh: ${STORE}: no such store directory" >&2
  exit 1
fi

[ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"
WINDOW_START="$(jq -rn --arg d "$TODAY" '($d | strptime("%Y-%m-%d") | mktime) - (90*86400) | gmtime | strftime("%Y-%m-%d")')"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_BUILD_STATS="${SCRIPT_DIR}/../../core/scripts/build-stats.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PEOPLE_DIR="${STORE}/people"
INTERACTIONS_DIR="${STORE}/interactions"
MODEL_FILE="${STORE}/user-model.md"

# ---------------------------------------------------------------------------
# Refusal check: an existing status: confirmed file is never overwritten
# unless --redraft (side-by-side draft instead).
# ---------------------------------------------------------------------------
OUT_FILE="$MODEL_FILE"
if [ -f "$MODEL_FILE" ]; then
  existing_status="$(awk '
    /^---$/ { fmcount++; if (fmcount == 2) exit; next }
    /^status:[ \t]*/ { v = $0; sub(/^status:[ \t]*/, "", v); print v; exit }
  ' "$MODEL_FILE")"
  if [ "$existing_status" = "confirmed" ]; then
    if [ "$REDRAFT" -eq 1 ]; then
      OUT_FILE="${STORE}/user-model.draft.md"
    else
      echo "derive-user-model.sh: refusing to overwrite a confirmed user-model.md; use --redraft to write a side-by-side draft" >&2
      exit 2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Resolve stats.json (same freshness rule as derive-evidence.sh).
# ---------------------------------------------------------------------------
STATS_JSON="${STORE}/stats.json"
NEED_RECOMPUTE=0
if [ ! -f "$STATS_JSON" ]; then
  NEED_RECOMPUTE=1
elif [ -d "$INTERACTIONS_DIR" ]; then
  stale="$(find "$INTERACTIONS_DIR" -name '*.md' -newer "$STATS_JSON" 2>/dev/null | head -n1)"
  [ -n "$stale" ] && NEED_RECOMPUTE=1
fi

if [ "$NEED_RECOMPUTE" -eq 1 ]; then
  SCRATCH_STORE="${WORK_DIR}/scratch-store"
  mkdir -p "$SCRATCH_STORE"
  [ -d "$PEOPLE_DIR" ] && ln -s "$PEOPLE_DIR" "$SCRATCH_STORE/people"
  [ -d "$INTERACTIONS_DIR" ] && ln -s "$INTERACTIONS_DIR" "$SCRATCH_STORE/interactions"
  bash "$CORE_BUILD_STATS" "$SCRATCH_STORE" >/dev/null
  STATS_JSON="$SCRATCH_STORE/stats.json"
fi

if [ ! -f "$STATS_JSON" ]; then
  echo "derive-user-model.sh: unable to resolve a stats.json for ${STORE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# source-capture map: interaction id -> source-capture value.
# ---------------------------------------------------------------------------
: > "${WORK_DIR}/srcmap.tsv"
if [ -d "$INTERACTIONS_DIR" ] && [ -n "$(ls -A "$INTERACTIONS_DIR"/*.md 2>/dev/null)" ]; then
  for f in $(ls "$INTERACTIONS_DIR"/*.md | sort); do
    printf '%s\n' "$f"
  done | awk '
    {
      file = $0
      id = file
      sub(/^.*\//, "", id)
      sub(/\.md$/, "", id)
      sc = ""
      while ((getline line < file) > 0) {
        if (line ~ /^source-capture:[ \t]*/) {
          v = line
          sub(/^source-capture:[ \t]*/, "", v)
          gsub(/^"|"$/, "", v)
          if (v == "null") v = ""
          sc = v
        }
      }
      close(file)
      printf "%s\t%s\n", id, sc
    }
  ' > "${WORK_DIR}/srcmap.tsv"
fi

SRCMAP_JSON="${WORK_DIR}/srcmap.json"
jq -Rn '
  [inputs | select(length > 0) | split("\t") | {(.[0]): (.[1] // "")}]
  | add // {}
' "${WORK_DIR}/srcmap.tsv" > "$SRCMAP_JSON"

# ---------------------------------------------------------------------------
# Person metadata: kind + tags, one JSON object per people/*.md.
# ---------------------------------------------------------------------------
: > "${WORK_DIR}/person-meta.jsonl"
if [ -d "$PEOPLE_DIR" ]; then
  for f in $(ls "$PEOPLE_DIR"/*.md 2>/dev/null | sort); do
    [ -e "$f" ] || continue
    slug="$(basename "$f" .md)"

    kind_val="$(awk '
      /^---$/ { fmcount++; if (fmcount == 2) exit; next }
      /^kind:[ \t]*/ { v = $0; sub(/^kind:[ \t]*/, "", v); print v; exit }
    ' "$f")"
    [ "$kind_val" = "null" ] && kind_val=""

    tags_line="$(awk '
      /^---$/ { fmcount++; if (fmcount == 2) exit; next }
      /^tags:[ \t]*/ { v = $0; sub(/^tags:[ \t]*/, "", v); print v; exit }
    ' "$f")"
    tags_json="$(printf '%s' "$tags_line" | jq -Rn '
      [inputs]
      | join("")
      | if . == "" then []
        else
          gsub("^\\[|\\]$"; "")
          | split(",")
          | map(gsub("^\\s+|\\s+$"; ""))
          | map(select(. != ""))
        end
    ')"

    jq -n \
      --arg slug "$slug" \
      --arg kind "$kind_val" \
      --argjson tags "$tags_json" \
      '{slug: $slug, kind: (if $kind == "" then null else $kind end), tags: $tags}' \
      >> "${WORK_DIR}/person-meta.jsonl"
  done
fi
PERSON_META_JSON="${WORK_DIR}/person-meta.json"
jq -s '.' "${WORK_DIR}/person-meta.jsonl" > "$PERSON_META_JSON"

# ---------------------------------------------------------------------------
# Similarity file (optional, passed through verbatim).
# ---------------------------------------------------------------------------
SIMILARITY_JSON="null"
if [ -n "$SIMILARITY_FILE" ]; then
  if [ ! -f "$SIMILARITY_FILE" ]; then
    echo "derive-user-model.sh: ${SIMILARITY_FILE}: no such similarity file" >&2
    exit 1
  fi
  SIMILARITY_JSON="$(cat "$SIMILARITY_FILE")"
fi

# ---------------------------------------------------------------------------
# Axis computation: one jq pass. Produces the five axis lines + unassigned,
# each with {share, meeting_share, weight, evidence, rationale}.
# ---------------------------------------------------------------------------
BODY_JSON="${WORK_DIR}/body.json"
jq -n \
  --slurpfile stats "$STATS_JSON" \
  --slurpfile srcmap "$SRCMAP_JSON" \
  --slurpfile personmeta "$PERSON_META_JSON" \
  --arg today "$TODAY" \
  --arg window_start "$WINDOW_START" \
  '
  ($stats[0]) as $stats
  | ($srcmap[0] // {}) as $src
  | ([$personmeta[0][]? | {(.slug): .}] | add // {}) as $pm
  | {
      friend: "friends", family: "family", collaborator: "business",
      professional: "business", community: "community",
      transactional: "transactional", scheduling: "transactional",
      unsolicited: "transactional"
    } as $kindmap
  | (
      $stats.people
      | to_entries
      | map(
          .key as $slug
          | .value as $v
          | ($pm[$slug] // {kind: null, tags: []}) as $meta
          | (
              ($v.interactions // [])
              | map(select(.date >= $window_start and .date <= $today))
            ) as $win
          | (
              if ($meta.kind != null and $meta.kind != "" and $meta.kind != "unknown" and ($kindmap[$meta.kind] != null))
              then $kindmap[$meta.kind]
              else (
                if ($win | any(.calendar == true and ((.others // []) | length) >= 1)) then "business"
                elif ($win | any(($src[.id] // "") as $s | ($s | contains("beeper-in-whatsapp")) or ($s | contains("beeper-in-matrix")))) then "friends"
                elif (($meta.tags // []) | index("family")) then "family"
                else "unassigned"
                end
              )
              end
            ) as $axis
          | {slug: $slug, axis: $axis, win: $win}
        )
    ) as $assigned
  | ([$assigned[] | .win[]] | length) as $total_ints
  | ([$assigned[] | .win[] | select(.calendar == true)] | length) as $total_meetings
  | (["business", "friends", "family", "community", "transactional", "unassigned"]) as $axes
  | (
      $axes
      | map(
          . as $axis
          | ([$assigned[] | select(.axis == $axis) | .win[]] | length) as $ints
          | ([$assigned[] | select(.axis == $axis) | .win[] | select(.calendar == true)] | length) as $meets
          | {
              axis: $axis,
              interactions: $ints,
              meetings: $meets,
              share: (if $total_ints == 0 then 0 else ($ints / $total_ints) end),
              meeting_share: (if $total_meetings == 0 then 0 else ($meets / $total_meetings) end)
            }
        )
    ) as $rows
  | ($rows | map(select(.axis != "unassigned") | .share) | max) as $max_share
  | {
      total_interactions: $total_ints,
      total_meetings: $total_meetings,
      rows: (
        $rows
        | map(
            . as $r
            | ((($r.share * 100) | round) / 100) as $w
            | ((($r.meeting_share * 100) | round) / 100) as $mw
            | (($r.interactions == 0 and $r.meetings == 0)) as $noevidence
            | {
                axis: $r.axis,
                weight: (if $noevidence then 0 else $w end),
                meeting_weight: (if $noevidence then 0 else $mw end),
                rationale: (
                  if $noevidence then "no evidence in window"
                  elif $r.axis == "unassigned" then "interactions that did not resolve to a kinded or heuristic axis in the last 90 days"
                  elif ($max_share != null and $r.share == $max_share and $max_share > 0) then "largest share of interactions in the last 90 days"
                  else "share of interactions in the last 90 days"
                  end
                )
              }
          )
      )
    }
  ' > "$BODY_JSON"

# ---------------------------------------------------------------------------
# Render the file.
# ---------------------------------------------------------------------------
fmt2() {
  # $1 = number -> "0.52" style, always 2 decimals
  awk -v n="$1" 'BEGIN { printf "%.2f", n }'
}

mix_line() {
  axis="$1"
  weight="$(jq -r --arg a "$axis" '.rows[] | select(.axis == $a) | .weight' "$BODY_JSON")"
  rationale="$(jq -r --arg a "$axis" '.rows[] | select(.axis == $a) | .rationale' "$BODY_JSON")"
  printf -- "- %s: %s — %s\n" "$axis" "$(fmt2 "$weight")" "$rationale"
}

revealed_line() {
  axis="$1"
  weight="$(jq -r --arg a "$axis" '.rows[] | select(.axis == $a) | .weight' "$BODY_JSON")"
  mweight="$(jq -r --arg a "$axis" '.rows[] | select(.axis == $a) | .meeting_weight' "$BODY_JSON")"
  rationale="$(jq -r --arg a "$axis" '.rows[] | select(.axis == $a) | .rationale' "$BODY_JSON")"
  printf -- "- %s: %s — %s (meetings: %s)\n" "$axis" "$(fmt2 "$weight")" "$rationale" "$(fmt2 "$mweight")"
}

TMP_OUT="${WORK_DIR}/user-model.md"

{
  printf '%s\n' "---"
  printf 'schema_version: 1.0.0\n'
  printf 'status: draft\n'
  printf 'derived_at: %s\n' "$TODAY"
  printf 'confirmed_at: null\n'
  printf 'revision: 0\n'
  printf 'provenance: observed-from-behavior\n'
  printf '%s\n' "---"
  printf '\n'
  printf '## Investment mix\n'
  printf '\n'
  for axis in business friends family community transactional; do
    mix_line "$axis"
  done
  printf '\n'
  printf '## Protected time\n'
  printf '\n'
  printf '<!-- Freeform: what the user keeps regardless of business load, e.g. "regular friends — weekly-ish hangs are non-negotiable". -->\n'
  printf '\n'
  printf '## Season\n'
  printf '\n'
  printf '<!-- Freeform + optional trailing "until: <YYYY-MM-DD>", e.g. "heads-down quarter, business-first until 2026-11-30". -->\n'
  printf '\n'
  printf '## Revealed vs stated\n'
  printf '\n'
  printf 'revealed (observed-from-behavior):\n'
  for axis in business friends family community transactional unassigned; do
    revealed_line "$axis"
  done
  if [ "$SIMILARITY_JSON" != "null" ]; then
    jq -r '
      "- embedding-similarity: business=\(.business) friends=\(.friends) family=\(.family) community=\(.community) transactional=\(.transactional) (\(.model), local)"
    ' <<< "$SIMILARITY_JSON"
  fi
  printf '\n'
  printf 'stated: none yet — draft awaiting confirmation.\n'
} > "$TMP_OUT"

mkdir -p "$(dirname "$OUT_FILE")"
mv "$TMP_OUT" "$OUT_FILE"
echo "derive-user-model.sh: wrote ${OUT_FILE}"
