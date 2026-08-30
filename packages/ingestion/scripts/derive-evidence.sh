#!/usr/bin/env bash
# derive-evidence.sh — deterministic per-person evidence JSON-lines, the
# input the plan-30 judgment pass and the review-tiers gate score against.
# packages/ingestion/specs/user-model-derive.md documents the sibling
# derive-user-model.sh; this script has no spec doc of its own (plan 30
# unit 7) — the field list below is the contract.
#
# Usage:
#   derive-evidence.sh <store> [--person <slug>] [--today YYYY-MM-DD]
#                       [--config <onboarding-backfill.tsv>]
#                       [--window-start YYYY-MM-DD]
#
# Emits one JSON object per person (sorted by slug — the order of
# stats.json's "people" map, itself built sorted by build-stats.sh's
# directory walk) to stdout, one per line (jq -c), fixed key order:
#
#   slug, touchpoints, median_gap_days, days_since_last, meetings,
#   chat_days, emails, user_initiated_share, participation, co_attended,
#   upcoming, talking_points, tier, kind, kind_source, kind_expires
#
# Field definitions:
#   touchpoints         stats.json people[slug].touchpoints
#   median_gap_days     stats.json people[slug].median_gap_days (null < 2)
#   days_since_last     today - last_interaction, in days; null if no
#                       interactions
#   meetings            count of this person's interactions whose
#                       calendar-event is non-null (stats.json's "calendar"
#                       bool) OR whose source-capture id contains
#                       "calendar-in"
#   chat_days           count of distinct dates among interactions whose
#                       source-capture contains "beeper-in"
#   emails              count of interactions whose source-capture contains
#                       "gmail-in"
#   user_initiated_share  0.0/1.0 — the derive-participation.sh
#                       user_engaged flag expressed as a float (coarse by
#                       design: this is a single 0/1 flag over the
#                       participation window, not a true fraction of
#                       interactions); null when participation is
#                       unavailable
#   participation       {user_engaged: 0|1, group_linked: 0|1} from
#                       derive-participation.sh, reused verbatim; null when
#                       unavailable
#   co_attended         count of this person's calendar interactions (as
#                       defined for "meetings") with >= 2 people entries
#   upcoming            earliest wakeups/*.md proposed-event.start date
#                       >= today among entries whose people includes
#                       [[slug]] and whose status is pending/fired, else
#                       null
#   talking_points       {count, items: [first 80 chars of each bullet
#                       under person.md's "## Open threads", "- " prefix
#                       stripped]}
#   tier / kind / kind_source / kind_expires   person.md frontmatter,
#                       null if absent
#
# --person <slug> restricts output to that one slug.
# --today defaults to today (UTC date).
# --config defaults to <store>/../config/onboarding-backfill.tsv (the
#   onboarding-backfill.md convention).
# --window-start defaults to <today> - 180 days.
#
# Participation is fetched via derive-participation.sh's own contract
# (packages/ingestion/scripts/derive-participation.sh):
#   derive-participation.sh <store-dir> <stats-json-path> <window-start-iso> <config-path>
# When the config is absent or the call fails (its fail-closed config
# posture), participation/user_initiated_share are null and exactly one
# stderr line is printed: "participation: unavailable (<reason>)" — this
# is lossy-tolerant, never an abort. derive-participation.sh itself reads
# inbox/ and archive/raw/ to resolve engagement signals; that read happens
# inside the delegated subprocess, not in this script's own file access.
#
# Read-only over <store>: people/, interactions/, wakeups/, stats.json.
# Never opens inbox/ or archive/ itself. If stats.json is absent or older
# than any interactions/*.md file, stats are recomputed via
# packages/core/scripts/build-stats.sh into a scratch directory (symlinked
# people/ and interactions/) — <store>/stats.json is never written by this
# script.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "derive-evidence.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "usage: derive-evidence.sh <store> [--person <slug>] [--today YYYY-MM-DD] [--config <path>] [--window-start YYYY-MM-DD]" >&2
  exit 1
fi

STORE="$1"
shift

PERSON_FILTER=""
TODAY=""
CONFIG_PATH=""
WINDOW_START=""

while [ $# -gt 0 ]; do
  case "$1" in
    --person)
      PERSON_FILTER="${2:-}"
      shift 2
      ;;
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --window-start)
      WINDOW_START="${2:-}"
      shift 2
      ;;
    *)
      echo "derive-evidence.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$STORE" ]; then
  echo "derive-evidence.sh: ${STORE}: no such store directory" >&2
  exit 1
fi

[ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"
[ -n "$CONFIG_PATH" ] || CONFIG_PATH="${STORE}/../config/onboarding-backfill.tsv"
if [ -z "$WINDOW_START" ]; then
  WINDOW_START="$(jq -rn --arg d "$TODAY" '($d | strptime("%Y-%m-%d") | mktime) - (180*86400) | gmtime | strftime("%Y-%m-%d")')"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_BUILD_STATS="${SCRIPT_DIR}/../../core/scripts/build-stats.sh"
CORE_DERIVE_PARTICIPATION="${SCRIPT_DIR}/derive-participation.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PEOPLE_DIR="${STORE}/people"
INTERACTIONS_DIR="${STORE}/interactions"
WAKEUPS_DIR="${STORE}/wakeups"

# ---------------------------------------------------------------------------
# Resolve stats.json: use <store>/stats.json when present and not older than
# any interactions/*.md file; else recompute into a scratch store (symlinks
# only — <store>/stats.json is never written by this script).
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
  echo "derive-evidence.sh: unable to resolve a stats.json for ${STORE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# source-capture map: interaction id -> source-capture value, one awk pass
# over interactions/*.md.
# ---------------------------------------------------------------------------
SRCMAP_JSON="${WORK_DIR}/srcmap.json"
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
        if (line ~ /^---$/ && sc != "" ) { }
      }
      close(file)
      printf "%s\t%s\n", id, sc
    }
  ' > "${WORK_DIR}/srcmap.tsv"
else
  : > "${WORK_DIR}/srcmap.tsv"
fi

jq -Rn '
  [inputs | select(length > 0) | split("\t") | {(.[0]): (.[1] // "")}]
  | add // {}
' "${WORK_DIR}/srcmap.tsv" > "$SRCMAP_JSON"

# ---------------------------------------------------------------------------
# Person metadata (kind fields + talking points), one JSON object per
# people/*.md, slurped into an array.
# ---------------------------------------------------------------------------
PERSON_META_JSON="${WORK_DIR}/person-meta.json"
: > "${WORK_DIR}/person-meta.jsonl"
if [ -d "$PEOPLE_DIR" ]; then
  for f in $(ls "$PEOPLE_DIR"/*.md 2>/dev/null | sort); do
    [ -e "$f" ] || continue
    slug="$(basename "$f" .md)"

    fm="$(awk '
      BEGIN { kind = ""; ksrc = ""; kexp = "" }
      /^---$/ { fmcount++; if (fmcount == 2) exit; next }
      {
        if ($0 ~ /^kind:[ \t]*/) { v = $0; sub(/^kind:[ \t]*/, "", v); kind = v }
        if ($0 ~ /^kind_source:[ \t]*/) { v = $0; sub(/^kind_source:[ \t]*/, "", v); ksrc = v }
        if ($0 ~ /^kind_expires:[ \t]*/) { v = $0; sub(/^kind_expires:[ \t]*/, "", v); kexp = v }
      }
      END { printf "%s\t%s\t%s\n", kind, ksrc, kexp }
    ' "$f")"
    kind_val="$(printf '%s' "$fm" | cut -f1)"
    ksrc_val="$(printf '%s' "$fm" | cut -f2)"
    kexp_val="$(printf '%s' "$fm" | cut -f3)"
    [ "$kind_val" = "null" ] && kind_val=""
    [ "$ksrc_val" = "null" ] && ksrc_val=""
    [ "$kexp_val" = "null" ] && kexp_val=""

    bullets="$(awk '
      /^## Open threads/ { insec = 1; next }
      /^## / { insec = 0 }
      insec && /^- / { sub(/^- /, ""); print }
    ' "$f")"

    # packages/ingestion/specs/currency.md "Consumers": drop an
    # "unverified since D" bullet when D is older than the person's
    # second-most-recent interaction date (stats.json people[slug].
    # interactions[] is sorted most-recent-first by build-stats.sh; index 1
    # is that date). Fewer than two interactions on file -> threshold empty,
    # nothing dropped (staleness can't be judged off a single touch). Bare
    # bullets and fresh "as-of" bullets (no "unverified since" marker) are
    # untouched. "## Resolved" bullets never reach here — the awk above
    # already stops the section at the next "## " heading.
    threshold_date="$(jq -r --arg slug "$slug" '(.people[$slug].interactions[1].date // empty)' "$STATS_JSON")"
    bullets="$(printf '%s\n' "$bullets" | while IFS= read -r bline; do
      [ -n "$bline" ] || continue
      unverified_date="$(printf '%s\n' "$bline" | sed -n 's/.*unverified since \([0-9][0-9-]*\).*/\1/p')"
      if [ -n "$unverified_date" ] && [ -n "$threshold_date" ] && [[ "$unverified_date" < "$threshold_date" ]]; then
        continue
      fi
      printf '%s\n' "$bline"
    done)"

    items_json="$(printf '%s\n' "$bullets" | jq -Rn '
      [inputs | select(length > 0) | .[0:80]]
    ')"
    [ -n "$bullets" ] || items_json="[]"

    jq -n \
      --arg slug "$slug" \
      --arg kind "$kind_val" \
      --arg ksrc "$ksrc_val" \
      --arg kexp "$kexp_val" \
      --argjson items "$items_json" \
      '{
        slug: $slug,
        kind: (if $kind == "" then null else $kind end),
        kind_source: (if $ksrc == "" then null else $ksrc end),
        kind_expires: (if $kexp == "" then null else $kexp end),
        talking_points: {count: ($items | length), items: $items}
      }' >> "${WORK_DIR}/person-meta.jsonl"
  done
fi
jq -s '.' "${WORK_DIR}/person-meta.jsonl" > "$PERSON_META_JSON"

# ---------------------------------------------------------------------------
# Wakeup map: slug -> earliest proposed-event.start date >= today among
# pending/fired entries.
# ---------------------------------------------------------------------------
WAKE_JSON="${WORK_DIR}/wake.json"
: > "${WORK_DIR}/wake.tsv"
if [ -d "$WAKEUPS_DIR" ]; then
  for f in $(ls "$WAKEUPS_DIR"/*.md 2>/dev/null | sort); do
    [ -e "$f" ] || continue
    awk '
      BEGIN { status = ""; kind = "nudge"; instart = 0; start = ""; peoplecount = 0 }
      /^---$/ { fmcount++; if (fmcount == 2) exit; next }
      {
        if ($0 ~ /^status:[ \t]*/) { v = $0; sub(/^status:[ \t]*/, "", v); status = v }
        if ($0 ~ /^kind:[ \t]*/) { v = $0; sub(/^kind:[ \t]*/, "", v); if (v != "" && v != "null") kind = v }
        if ($0 ~ /^people:[ \t]*/) {
          rest = $0
          while (match(rest, /\[\[[a-z0-9-]+\]\]/)) {
            s = substr(rest, RSTART + 2, RLENGTH - 4)
            peoplecount++
            people[peoplecount] = s
            rest = substr(rest, RSTART + RLENGTH)
          }
        }
        if ($0 ~ /^proposed-event:[ \t]*/) { instart = 1; next }
        if (instart == 1) {
          if ($0 ~ /^[ \t]+start:[ \t]*/) {
            v = $0
            sub(/^[ \t]+start:[ \t]*/, "", v)
            gsub(/^"|"$/, "", v)
            start = v
          } else if ($0 !~ /^[ \t]+[A-Za-z0-9_-]+:/) {
            instart = 0
          }
        }
      }
      END {
        if ((status == "pending" || status == "fired") && kind == "event-proposal" && start != "" && start != "null") {
          date = substr(start, 1, 10)
          for (i = 1; i <= peoplecount; i++) printf "%s\t%s\n", people[i], date
        }
      }
    ' "$f" >> "${WORK_DIR}/wake.tsv"
  done
fi

jq -Rn --arg today "$TODAY" '
  [inputs | select(length > 0) | split("\t") | {slug: .[0], date: .[1]}]
  | group_by(.slug)
  | map({(.[0].slug): ([.[] | .date | select(. >= $today)] | sort | (.[0] // null))})
  | add // {}
' "${WORK_DIR}/wake.tsv" > "$WAKE_JSON"

# ---------------------------------------------------------------------------
# Participation (lossy-tolerant): fetch via derive-participation.sh; on
# absent config or a failed call, emit one stderr line and fall back to
# unavailable (null participation / null user_initiated_share).
# ---------------------------------------------------------------------------
PART_AVAILABLE=0
PART_JSON="${WORK_DIR}/part.json"
echo '{}' > "$PART_JSON"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "participation: unavailable (config absent: ${CONFIG_PATH})" >&2
else
  PART_ERR="${WORK_DIR}/part.err"
  if PART_TSV="$(bash "$CORE_DERIVE_PARTICIPATION" "$STORE" "$STATS_JSON" "$WINDOW_START" "$CONFIG_PATH" 2>"$PART_ERR")"; then
    PART_AVAILABLE=1
    printf '%s\n' "$PART_TSV" | jq -Rn '
      [inputs | select(length > 0) | split("\t") | {(.[0]): {user_engaged: (.[1] | tonumber), group_linked: (.[2] | tonumber)}}]
      | add // {}
    ' > "$PART_JSON"
  else
    reason="$(head -n1 "$PART_ERR" 2>/dev/null)"
    [ -n "$reason" ] || reason="derive-participation.sh failed"
    echo "participation: unavailable (${reason})" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Final assembly.
# ---------------------------------------------------------------------------
jq -c \
  --slurpfile srcmap "$SRCMAP_JSON" \
  --slurpfile personmeta "$PERSON_META_JSON" \
  --slurpfile wake "$WAKE_JSON" \
  --slurpfile part "$PART_JSON" \
  --arg today "$TODAY" \
  --arg person_filter "$PERSON_FILTER" \
  --argjson part_available "$([ "$PART_AVAILABLE" -eq 1 ] && echo true || echo false)" \
  '
  ($srcmap[0] // {}) as $src
  | ($wake[0] // {}) as $wk
  | ($part[0] // {}) as $pt
  | (
      [$personmeta[0][]? | {(.slug): .}]
      | add // {}
    ) as $pm
  | .people
  | to_entries
  | sort_by(.key)
  | .[]
  | select($person_filter == "" or .key == $person_filter)
  | .key as $slug
  | .value as $v
  | ($pm[$slug] // {kind: null, kind_source: null, kind_expires: null, talking_points: {count: 0, items: []}}) as $meta
  | ($v.interactions // []) as $ints
  | (
      $ints
      | map(. as $i | $i + {source: ($src[$i.id] // "")})
    ) as $intsrc
  | (
      $intsrc
      | map(select(.calendar == true or (.source | contains("calendar-in"))))
    ) as $meetingInts
  | {
      slug: $slug,
      touchpoints: $v.touchpoints,
      median_gap_days: $v.median_gap_days,
      days_since_last: (
        if $v.last_interaction == null then null
        else (
          (($today | strptime("%Y-%m-%d") | mktime) - ($v.last_interaction | strptime("%Y-%m-%d") | mktime)) / 86400
          | round
        )
        end
      ),
      meetings: ($meetingInts | length),
      chat_days: (
        $intsrc
        | map(select(.source | contains("beeper-in")))
        | map(.date)
        | unique
        | length
      ),
      emails: (
        $intsrc
        | map(select(.source | contains("gmail-in")))
        | length
      ),
      user_initiated_share: (
        if $part_available then (($pt[$slug].user_engaged // 0) * 1.0) else null end
      ),
      participation: (
        if $part_available then {
          user_engaged: ($pt[$slug].user_engaged // 0),
          group_linked: ($pt[$slug].group_linked // 0)
        } else null end
      ),
      co_attended: (
        $meetingInts
        | map(select((.others | length) >= 1))
        | length
      ),
      upcoming: ($wk[$slug] // null),
      talking_points: $meta.talking_points,
      tier: $v.tier,
      kind: $meta.kind,
      kind_source: $meta.kind_source,
      kind_expires: $meta.kind_expires
    }
  ' "$STATS_JSON"
