#!/usr/bin/env bash
# suggest-tiers.sh — apply the plan-24 D3 deterministic scoring model to
# produce the presented onboarding tier-suggestion batch (plan 24 unit 8).
# packages/ingestion/specs/onboarding-tiering-seed.md ("Tier suggestions"
# section) is the model of record; this script is a pure read/compute pass
# — it writes nothing anywhere and nothing here is ever persisted to any
# file by itself (suggestions become real `tier` writes only via a later,
# separate, human-confirmed stated-preference-filing call, out of scope
# here).
#
# Usage:
#   suggest-tiers.sh <stats-json-path> <participation-tsv-path> <window-start-iso>
#
# <stats-json-path>  packages/core/contracts/derived-index.md's stats.json.
# <participation-tsv-path>  this plan's unit 7 output
#   (derive-participation.sh): slug<TAB>user_engaged<TAB>group_linked rows,
#   0/1 each.
# <window-start-iso>  bounds which stats.json interactions count toward the
#   `co-attended` signal (an interaction only counts if its `date` is
#   `>= <window-start-iso>`, mirroring unit 7's own windowing).
#
# Model:
#   1. Gate: touchpoints < 2 -> excluded, no row at all.
#   2. Base band from median_gap_days (ties fall to the closer/warmer
#      tier): <=21 inner-circle(3), <=45 close(2), <=90 active(1),
#      >90 dormant(0).
#   3. Signals: user-engaged(+2) if the TSV's user_engaged=1;
#      co-attended(+1) if >=1 in-window stats interaction has
#      calendar:true. Boosts are cumulative. Penalty classes apply only
#      when BOTH boosts are absent (mutually exclusive by the group test):
#      silent-group (score forced 0) if group_linked=1, else
#      never-answered (score forced -1).
#   4. Final score = clamp(base + boosts, -1, 3); a penalty sets the score
#      directly, overriding the base band. Tier from score: 3
#      inner-circle, 2 close, 1 active, <=0 dormant.
#   5. Ordering: score desc, median_gap_days asc, touchpoints desc, slug
#      asc. Cap: first 20 rows only — the rest are simply not presented
#      (no-backlog rule; not an error, not queued).
#
# A slug present in stats.json but absent from the participation TSV is
# treated as user_engaged=0/group_linked=0, with a stderr warning — never
# an abort (same lossy-tolerant posture as unit 7).
#
# Output: deterministic TSV to stdout, one row per presented person, in
# final order:
#   slug<TAB>score<TAB>suggested_tier<TAB><breakdown>
# breakdown = "suggested: <tier> | base: <band> (median_gap_days=<n>) |
# signals: <comma list with deltas>" (or "signals: none" if neither boost
# nor penalty applies — unreachable under the current model since the two
# penalty classes exhaustively cover the no-boost case, kept for
# robustness); penalty rows render that last segment as
# "class: never-answered (very low)" / "class: silent-group (low)"
# instead. Nothing else goes to stdout; diagnostics go to stderr.
#
# Read-only: writes nothing anywhere, on any exit path.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if [ $# -ne 3 ]; then
  echo "usage: suggest-tiers.sh <stats-json-path> <participation-tsv-path> <window-start-iso>" >&2
  exit 1
fi

STATS_JSON="$1"
PARTICIPATION_TSV="$2"
WINDOW_START="$3"

if ! command -v jq >/dev/null 2>&1; then
  echo "suggest-tiers.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ ! -f "$STATS_JSON" ]; then
  echo "suggest-tiers.sh: ${STATS_JSON}: no such stats.json file" >&2
  exit 1
fi

if [ ! -f "$PARTICIPATION_TSV" ]; then
  echo "suggest-tiers.sh: ${PARTICIPATION_TSV}: no such participation TSV file" >&2
  exit 1
fi

MERGED="$(mktemp)"
trap 'rm -f "$MERGED"' EXIT

# ---------------------------------------------------------------------------
# Gate: slugs with touchpoints >= 2, one per line.
# ---------------------------------------------------------------------------
GATED_SLUGS="$(jq -r '.people | to_entries[] | select(.value.touchpoints >= 2) | .key' "$STATS_JSON")"

# ---------------------------------------------------------------------------
# Resolve each gated slug's participation row from the TSV; missing ->
# default 0/0 with a stderr warning (lossy-tolerant, never aborts).
# ---------------------------------------------------------------------------
if [ -n "$GATED_SLUGS" ]; then
  printf '%s\n' "$GATED_SLUGS" | while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    row="$(awk -F'\t' -v s="$slug" '$1 == s { print; found = 1; exit } END { if (!found) exit 1 }' "$PARTICIPATION_TSV" || true)"
    if [ -z "$row" ]; then
      echo "suggest-tiers.sh: slug '${slug}' missing from participation TSV — defaulting to user_engaged=0 group_linked=0" >&2
      row="$(printf '%s\t0\t0' "$slug")"
    fi
    printf '%s\n' "$row" >> "$MERGED"
  done
fi

# ---------------------------------------------------------------------------
# Build the participation array as JSON for jq to consume alongside
# stats.json.
# ---------------------------------------------------------------------------
PART_JSON="[]"
if [ -s "$MERGED" ]; then
  PART_JSON="$(awk -F'\t' '{printf "{\"slug\":%s,\"user_engaged\":%s,\"group_linked\":%s}\n", "\"" $1 "\"", $2, $3}' "$MERGED" | jq -s '.')"
fi

TMP_JQ="$(mktemp)"
trap 'rm -f "$MERGED" "$TMP_JQ"' EXIT

cat > "$TMP_JQ" <<'JQ_EOF'
($part | map({(.slug): {user_engaged: .user_engaged, group_linked: .group_linked}}) | add // {}) as $partMap
| [
    .people
    | to_entries[]
    | select(.value.touchpoints >= 2)
    | .key as $slug
    | .value as $v
    | $v.median_gap_days as $gap
    | (
        if $gap <= 21 then {band: "inner-circle", pts: 3}
        elif $gap <= 45 then {band: "close", pts: 2}
        elif $gap <= 90 then {band: "active", pts: 1}
        else {band: "dormant", pts: 0}
        end
      ) as $base
    | ($partMap[$slug] // {user_engaged: 0, group_linked: 0}) as $sig
    | (($v.interactions // []) | any(.calendar == true and .date >= $ws)) as $coattended
    | ($sig.user_engaged == 1) as $engaged
    | (if $engaged then 2 else 0 end) as $engagedPts
    | (if $coattended then 1 else 0 end) as $coPts
    | (
        if ($engaged or $coattended) then null
        elif $sig.group_linked == 1 then "silent-group"
        else "never-answered"
        end
      ) as $penalty
    | (
        if $penalty == "silent-group" then 0
        elif $penalty == "never-answered" then -1
        else ([($base.pts + $engagedPts + $coPts), 3] | min | [., -1] | max)
        end
      ) as $score
    | (
        if $score >= 3 then "inner-circle"
        elif $score == 2 then "close"
        elif $score == 1 then "active"
        else "dormant"
        end
      ) as $suggested
    | (
        if $penalty == "silent-group" then "class: silent-group (low)"
        elif $penalty == "never-answered" then "class: never-answered (very low)"
        else (
          [
            (if $engaged then "user-engaged(+2)" else empty end),
            (if $coattended then "co-attended(+1)" else empty end)
          ] as $sigList
          | if ($sigList | length) == 0 then "signals: none"
            else "signals: " + ($sigList | join(", "))
            end
        )
        end
      ) as $sigSeg
    | {
        slug: $slug,
        score: $score,
        suggested: $suggested,
        median_gap_days: $gap,
        touchpoints: $v.touchpoints,
        breakdown: ("suggested: " + $suggested + " | base: " + $base.band + " (median_gap_days=" + ($gap | tostring) + ") | " + $sigSeg)
      }
  ]
| sort_by(-.score, .median_gap_days, -.touchpoints, .slug)
| .[0:20]
| .[]
| [.slug, (.score | tostring), .suggested, .breakdown]
| @tsv
JQ_EOF

jq -r \
  --argjson part "$PART_JSON" \
  --arg ws "$WINDOW_START" \
  -f "$TMP_JQ" \
  "$STATS_JSON"
