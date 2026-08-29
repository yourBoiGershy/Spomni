#!/bin/bash
# calibrate.sh — SKETCH implementation of packages/attention/specs/calibration.md
# (plan 11 unit 9). Aggregates <store-dir>/wakeups/*.md outcome history into
# a full rewrite of <store-dir>/ranking-weights.json per
# packages/core/contracts/ranking-weights.md.
#
# CALLER: this script is a step in plan 06's sweep pipeline
# (skills/sweep/SKILL.md), invoked AFTER "acted-on detection"
# (packages/attention/specs/outcome-recording.md) and before delivery via an
# output adapter:
#
#   ... -> fire due wake-ups -> acted-on detection -> calibrate (this script) -> deliver
#
# It is not meant to be a finished, hardened CLI yet — this is a sketch that
# implements the calibration.md formula end-to-end so plan 06's sweep has a
# concrete, testable step to call, and so fixtures (plan 11 unit 11) have
# something to run against. See calibration.md for the full spec, formula
# derivation, clamps, and the flagged signal-type gap (section 2.1).
#
# Usage: calibrate.sh <store-dir> [--window-days <n>]   (default window: 90)
#
# Reads:  <store-dir>/wakeups/*.md, <store-dir>/people/*.md (tags only),
#         <store-dir>/ranking-weights.json (if present, as the per-step
#         clamp baseline).
# Writes: <store-dir>/ranking-weights.json (full rewrite; sole write this
#         script performs on that file).
# Side effect: may create at most one new wakeups/<id>.md suppression
#         proposal per person per run, via packages/core/scripts/wakeup-add.sh
#         (calibration.md section 4) — never writes wakeups/ fields itself.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.
# Uses jq for aggregation math (already a dependency of
# packages/core/scripts/build-stats.sh — same convention followed here).

set -eu

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAKEUP_ADD="${SCRIPT_DIR}/../../core/scripts/wakeup-add.sh"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> [--window-days <n>]

Aggregates <store-dir>/wakeups/*.md outcome history into a full rewrite of
<store-dir>/ranking-weights.json. See packages/attention/specs/calibration.md.
EOF
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi

STORE_DIR="$1"
shift

WINDOW_DAYS=90
while [ "$#" -gt 0 ]; do
  case "$1" in
    --window-days)
      [ "$#" -ge 2 ] || usage
      WINDOW_DAYS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ ! -d "${STORE_DIR}" ]; then
  echo "${SCRIPT_NAME}: store directory does not exist: '${STORE_DIR}'" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "${SCRIPT_NAME}: jq is required but not found on PATH" >&2
  exit 1
fi

WAKEUPS_DIR="${STORE_DIR}/wakeups"
PEOPLE_DIR="${STORE_DIR}/people"
WEIGHTS_PATH="${STORE_DIR}/ranking-weights.json"

TMP_WAKEUPS="$(mktemp)"
TMP_PEOPLE="$(mktemp)"
TMP_PREV="$(mktemp)"
TMP_JQ="$(mktemp)"
TMP_JQ_MAIN="$(mktemp)"
TMP_OUT="$(mktemp)"
TMP_SUPPRESS="$(mktemp)"
trap 'rm -f "$TMP_WAKEUPS" "$TMP_PEOPLE" "$TMP_PREV" "$TMP_JQ" "$TMP_JQ_MAIN" "$TMP_OUT" "$TMP_SUPPRESS"' EXIT

TODAY="$(date -u +%Y-%m-%d)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Extract wakeups/*.md frontmatter into JSON-lines -----------------------
#
# One JSON object per file: id, due, fired_on, status, dismiss_reason,
# acted_on (bool or null), snooze_count, origin, signal_type (frontmatter
# field if present, else null — see calibration.md section 2.1), why,
# people (array of slugs).

if [ -d "${WAKEUPS_DIR}" ] && [ -n "$(ls -A "${WAKEUPS_DIR}"/*.md 2>/dev/null)" ]; then
  for f in $(ls "${WAKEUPS_DIR}"/*.md | sort); do
    printf '%s\n' "$f"
  done | awk '
    function esc(s) { gsub(/"/, "\\\"", s); return s }
    function flush() {
      if (id == "") return
      printf "{\"id\":\"%s\",\"due\":", esc(id)
      if (due == "") printf "null"; else printf "\"%s\"", due
      printf ",\"fired_on\":"
      if (fired_on == "") printf "null"; else printf "\"%s\"", fired_on
      printf ",\"status\":"
      if (status == "") printf "null"; else printf "\"%s\"", status
      printf ",\"dismiss_reason\":"
      if (dismiss_reason == "" || dismiss_reason == "null") printf "null"; else printf "\"%s\"", dismiss_reason
      printf ",\"acted_on\":"
      if (acted_on == "true") printf "true"
      else if (acted_on == "false") printf "false"
      else printf "null"
      printf ",\"snooze_count\":%d", (snooze_count == "" ? 0 : snooze_count)
      printf ",\"origin\":"
      if (origin == "") printf "null"; else printf "\"%s\"", origin
      printf ",\"signal_type\":"
      if (signal_type == "" || signal_type == "null") printf "null"; else printf "\"%s\"", signal_type
      printf ",\"why\":\"%s\"", esc(why)
      printf ",\"people\":["
      for (i = 1; i <= peoplecount; i++) {
        if (i > 1) printf ","
        printf "\"%s\"", people[i]
      }
      printf "]}\n"
    }
    {
      file = $0
      id = file
      sub(/^.*\//, "", id)
      sub(/\.md$/, "", id)
      due = ""; fired_on = ""; status = ""; dismiss_reason = ""
      acted_on = ""; snooze_count = ""; origin = ""; signal_type = ""; why = ""
      peoplecount = 0
      delete people
      infm = 0
      fmlines = 0
      while ((getline line < file) > 0) {
        if (line == "---") {
          fmlines++
          if (fmlines == 1) { infm = 1; continue }
          if (fmlines == 2) { infm = 0; break }
        }
        if (!infm) continue
        if (line ~ /^due: /) { val = line; sub(/^due: */, "", val); due = val; continue }
        if (line ~ /^fired-on: /) { val = line; sub(/^fired-on: */, "", val); fired_on = val; continue }
        if (line ~ /^status: /) { val = line; sub(/^status: */, "", val); status = val; continue }
        if (line ~ /^dismiss-reason: /) { val = line; sub(/^dismiss-reason: */, "", val); dismiss_reason = val; continue }
        if (line ~ /^acted-on: /) { val = line; sub(/^acted-on: */, "", val); acted_on = val; continue }
        if (line ~ /^snooze-count: /) { val = line; sub(/^snooze-count: */, "", val); snooze_count = val; continue }
        if (line ~ /^origin: /) { val = line; sub(/^origin: */, "", val); origin = val; continue }
        if (line ~ /^signal-type: /) { val = line; sub(/^signal-type: */, "", val); signal_type = val; continue }
        if (line ~ /^why: /) {
          val = line
          sub(/^why: */, "", val)
          gsub(/^"|"$/, "", val)
          why = val
          continue
        }
        if (line ~ /^people: /) {
          rest = line
          while (match(rest, /\[\[[a-z0-9-]+\]\]/)) {
            slug = substr(rest, RSTART + 2, RLENGTH - 4)
            peoplecount++
            people[peoplecount] = slug
            rest = substr(rest, RSTART + RLENGTH)
          }
          continue
        }
      }
      close(file)
      flush()
    }
  ' > "${TMP_WAKEUPS}"
else
  : > "${TMP_WAKEUPS}"
fi

# --- Extract people/*.md tags (frontmatter `tags: [a, b]`) -----------------

if [ -d "${PEOPLE_DIR}" ] && [ -n "$(ls -A "${PEOPLE_DIR}"/*.md 2>/dev/null)" ]; then
  for f in $(ls "${PEOPLE_DIR}"/*.md | sort); do
    printf '%s\n' "$f"
  done | awk '
    function flush() {
      if (slug == "") return
      printf "{\"slug\":\"%s\",\"tags\":[", slug
      for (i = 1; i <= tagcount; i++) {
        if (i > 1) printf ","
        printf "\"%s\"", tags[i]
      }
      printf "]}\n"
    }
    {
      file = $0
      slug = file
      sub(/^.*\//, "", slug)
      sub(/\.md$/, "", slug)
      tagcount = 0
      delete tags
      infm = 0
      fmlines = 0
      while ((getline line < file) > 0) {
        if (line == "---") {
          fmlines++
          if (fmlines == 1) { infm = 1; continue }
          if (fmlines == 2) { infm = 0; break }
        }
        if (!infm) continue
        if (line ~ /^tags: /) {
          rest = line
          sub(/^tags: */, "", rest)
          gsub(/^\[|\]$/, "", rest)
          n = split(rest, parts, ",")
          for (i = 1; i <= n; i++) {
            t = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (t != "") { tagcount++; tags[tagcount] = t }
          }
          continue
        }
      }
      close(file)
      flush()
    }
  ' > "${TMP_PEOPLE}"
else
  : > "${TMP_PEOPLE}"
fi

# --- Previous ranking-weights.json (clamp baseline) -------------------------

if [ -f "${WEIGHTS_PATH}" ]; then
  cp "${WEIGHTS_PATH}" "${TMP_PREV}"
else
  printf '{"schema_version":"1.0.0","generated_at":null,"weights":{"signal-types":{},"tags":{}}}\n' > "${TMP_PREV}"
fi

# --- jq aggregation: calibration.md sections 1-5 ----------------------------

cat > "${TMP_JQ}" <<'JQ_EOF'
def within_window($anchor):
  ($anchor | strptime("%Y-%m-%d") | mktime) as $t
  | ($today | strptime("%Y-%m-%d") | mktime) as $today_t
  | ($window_days * 86400) as $win_secs
  | ($t > ($today_t - $win_secs)) and ($t <= $today_t);

def anchor_date:
  if .fired_on != null then .fired_on else .due end;

def in_window:
  (anchor_date != null) and within_window(anchor_date);

# Signal-type keys an entry contributes to (0 or 1 key per entry).
def signal_type_keys:
  if .origin == "user-ask" then []
  elif .signal_type != null then [.signal_type]
  else ["unclassified"]
  end;

# One deterministic adjustment formula, applied to both dimensions
# (calibration.md section 3). $negfield names the counter that supplies the
# downward pressure for this dimension; $roundlabel selects rationale
# phrasing ("signal-types" vs. any other value == tags phrasing).
def adjust($stats; $prevmap; $negfield; $roundlabel):
  ($stats | to_entries | map(
    .key as $k
    | .value as $s
    | ($prevmap[$k].weight // 1.0) as $prior
    | if $s.fired < 3 then
        ($prevmap[$k] // null) as $keep
        | if $keep == null then empty else {key: $k, value: $keep} end
      else
        ($s.acted_on_true / $s.fired) as $acted_rate
        | ($s[$negfield] / $s.fired) as $neg_rate
        | ($acted_rate - $neg_rate) as $raw
        | ([[$raw, -0.15] | max, 0.15] | min) as $step
        | ([[($prior + $step), 0.25] | max, 2.0] | min) as $new_w_raw
        | (($new_w_raw * 100 | round) / 100) as $new_w
        | if $new_w == $prior then
            ($prevmap[$k] // null) as $keep
            | if $keep == null then empty else {key: $k, value: $keep} end
          else
            {
              key: $k,
              value: {
                weight: $new_w,
                updated: $today,
                rationale: (
                  if $step < 0 then
                    ($s[$negfield] | tostring) + " of " + ($s.fired | tostring) + " " + $k +
                    (if $roundlabel == "signal-types" then " nudges dismissed not-this-signal-type in " else "-tagged nudges dismissed (excl. not-this-person) in " end) +
                    ($window_days | tostring) + "d" +
                    (if ($roundlabel == "signal-types" and $k == "unclassified") then " (signal-type not recorded on these wake-ups — see calibration.md §2.1)" else "" end)
                  else
                    "acted on " + ($s.acted_on_true | tostring) + " of " + ($s.fired | tostring) + " fired nudges"
                  end
                )
              }
            }
          end
      end
  ) | map(select(. != null)) | from_entries);

($wakeups | map(select(in_window))) as $inwin

# --- signal-types dimension ---
| (reduce $inwin[] as $e (
    {};
    reduce (($e | signal_type_keys)[]) as $k (
      .;
      .[$k] = ((.[$k] // {fired:0, acted_on_true:0, dismissed_total:0,
                            dismissed_not_this_signal_type:0,
                            dismissed_not_this_person:0, dismissed_other:0,
                            snoozed_total:0})
        | .fired += (if $e.fired_on != null then 1 else 0 end)
        | .acted_on_true += (if $e.acted_on == true then 1 else 0 end)
        | .dismissed_total += (if $e.status == "dismissed" then 1 else 0 end)
        | .dismissed_not_this_signal_type += (if $e.dismiss_reason == "not-this-signal-type" then 1 else 0 end)
        | .dismissed_not_this_person += (if $e.dismiss_reason == "not-this-person" then 1 else 0 end)
        | .dismissed_other += (if (($e.dismiss_reason == "not-now") or ($e.dismiss_reason == "already-handled")) then 1 else 0 end)
        | .snoozed_total += $e.snooze_count
      )
    )
  )) as $sigStats

# --- tags dimension: join each entry's people to their tags ---
| (reduce $inwin[] as $e (
    {};
    (reduce $e.people[] as $slug (
      [];
      . + ($people_by_slug[$slug].tags // [])
    ) | unique) as $tagkeys
    | reduce $tagkeys[] as $k (
      .;
      .[$k] = ((.[$k] // {fired:0, acted_on_true:0, dismissed_total:0,
                            dismissed_not_this_signal_type:0,
                            dismissed_not_this_person:0, dismissed_other:0,
                            snoozed_total:0})
        | .fired += (if $e.fired_on != null then 1 else 0 end)
        | .acted_on_true += (if $e.acted_on == true then 1 else 0 end)
        | .dismissed_total += (if $e.status == "dismissed" then 1 else 0 end)
        | .dismissed_not_this_signal_type += (if $e.dismiss_reason == "not-this-signal-type" then 1 else 0 end)
        | .dismissed_not_this_person += (if $e.dismiss_reason == "not-this-person" then 1 else 0 end)
        | .dismissed_other += (if (($e.dismiss_reason == "not-now") or ($e.dismiss_reason == "already-handled")) then 1 else 0 end)
        | .snoozed_total += $e.snooze_count
      )
    )
  )) as $tagStats

# --- adjustment formula (calibration.md section 3) ---
# tags' negative field is derived (dismissed_total - dismissed_not_this_person)
# and computed inline since adjust() expects a plain field name on $stats.
| adjust($sigStats; ($prev.weights["signal-types"] // {}); "dismissed_not_this_signal_type"; "signal-types") as $newSig
| ($tagStats | with_entries(.value.dismissed_total_minus_not_this_person = (.value.dismissed_total - .value.dismissed_not_this_person))) as $tagStats2
| adjust($tagStats2; ($prev.weights["tags"] // {}); "dismissed_total_minus_not_this_person"; "tags") as $newTag

# --- per-person not-this-person suppression candidates (section 4) ---
| (reduce $inwin[] as $e (
    {};
    if $e.dismiss_reason == "not-this-person" then
      reduce $e.people[] as $slug (
        .;
        .[$slug] = ((.[$slug] // {count: 0, ids: []})
          | .count += 1
          | .ids += [$e.id]
        )
      )
    else . end
  )) as $notThisPerson
| ($notThisPerson | to_entries | map(select(.value.count >= 2))
   | map({slug: .key, count: .value.count, ids: .value.ids})) as $suppressCandidates

| {
    ranking_weights: {
      schema_version: "1.0.0",
      generated_at: $generated_at,
      weights: {
        "signal-types": $newSig,
        "tags": $newTag
      }
    },
    suppression_candidates: $suppressCandidates
  }
JQ_EOF

{
  printf '%s\n' '($wakeups_raw) as $wakeups | ($people_raw | map({(.slug): {tags: .tags}}) | add // {}) as $people_by_slug |'
  cat "${TMP_JQ}"
} > "${TMP_JQ_MAIN}"

jq -n \
  --slurpfile wakeups_raw "${TMP_WAKEUPS}" \
  --slurpfile people_raw "${TMP_PEOPLE}" \
  --argjson prev "$(cat "${TMP_PREV}")" \
  --arg today "${TODAY}" \
  --arg generated_at "${GENERATED_AT}" \
  --argjson window_days "${WINDOW_DAYS}" \
  -f "${TMP_JQ_MAIN}" \
  > "${TMP_OUT}"

jq -S '.ranking_weights' "${TMP_OUT}" > "${WEIGHTS_PATH}"
jq -c '.suppression_candidates[]' "${TMP_OUT}" > "${TMP_SUPPRESS}"

# --- Fire suppression proposals (calibration.md section 4) ------------------
#
# One wakeup-add.sh call per new candidate slug, guarded against duplicates:
# skip if a pending/fired wake-up already proposes suppression for that slug
# (matched by the "stop nudging about [[<slug>]]" sentinel prefix in `why`).

if [ -s "${TMP_SUPPRESS}" ] && [ -x "${WAKEUP_ADD}" ]; then
  while IFS= read -r candidate; do
    slug="$(printf '%s' "$candidate" | jq -r '.slug')"
    count="$(printf '%s' "$candidate" | jq -r '.count')"
    ids="$(printf '%s' "$candidate" | jq -r '.ids | join(", ")')"

    already_proposed=0
    if [ -d "${WAKEUPS_DIR}" ]; then
      for wf in "${WAKEUPS_DIR}"/*.md; do
        [ -e "${wf}" ] || continue
        if grep -q "why: \"stop nudging about \[\[${slug}\]\]" "${wf}" \
          && grep -Eq '^status: (pending|fired)$' "${wf}"; then
          already_proposed=1
          break
        fi
      done
    fi

    if [ "${already_proposed}" -eq 0 ]; then
      # wakeup-add.sh requires a non-null --source-signal for --origin signal
      # (it names the wakeups/signals/<id>.md this entry was promoted from).
      # A calibration-generated suppression proposal has no such signal-event
      # file behind it (plan 05's signal-event.md is unbuilt) — this synthetic
      # id is a placeholder flagged the same way as the signal-type gap
      # (calibration.md section 2.1); revisit once plan 05/06 land.
      "${WAKEUP_ADD}" "${STORE_DIR}" \
        --due "${TODAY}" \
        --person "${slug}" \
        --why "stop nudging about [[${slug}]]? ${count} not-this-person dismissals in ${WINDOW_DAYS}d" \
        --origin signal \
        --source-signal "calibration-suppression-${slug}-${TODAY}" \
        --context "${count} wake-ups about [[${slug}]] were dismissed not-this-person in the last ${WINDOW_DAYS} days: ${ids}. Confirming this proposal opts [[${slug}]] out via profile.md's Signal opt-outs (ingestion files it after user confirmation; attention never writes profile.md)." \
        >/dev/null
    fi
  done < "${TMP_SUPPRESS}"
fi

echo "ranking-weights.json calibrated (window: ${WINDOW_DAYS}d) -> ${WEIGHTS_PATH}"
