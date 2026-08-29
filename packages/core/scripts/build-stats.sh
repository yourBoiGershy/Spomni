#!/bin/bash
# build-stats.sh — walk <store-dir>/people/*.md and <store-dir>/interactions/*.md
# and emit <store-dir>/stats.json per packages/core/contracts/derived-index.md.
#
# Usage: build-stats.sh [store-dir]   (defaults to ".")
#
# For each people/<slug>.md, computes touchpoints/first_interaction/
# last_interaction/median_gap_days/open_threads/commitments/interactions by
# scanning interactions/*.md fresh (never trusting person.md's last-touch).
# Every person in people/ appears, including people with zero interactions.
# Absent interactions/ is not an error — treated as zero interactions.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.
# Batches parsing with two whole-directory awk passes (one for people/, one
# for interactions/) and a single jq aggregation pass, instead of spawning
# jq per file, to stay inside the <5s / 1000-people / ~10k-interactions
# perf envelope.

set -eu

STORE_DIR="${1:-.}"
PEOPLE_DIR="${STORE_DIR}/people"
INTERACTIONS_DIR="${STORE_DIR}/interactions"
STATS_PATH="${STORE_DIR}/stats.json"

if [ ! -d "$PEOPLE_DIR" ]; then
  echo "build-stats.sh: no people/ directory found at ${PEOPLE_DIR}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "build-stats.sh: jq is required but not found on PATH" >&2
  exit 1
fi

TMP_PEOPLE="$(mktemp)"
TMP_INTERACTIONS="$(mktemp)"
TMP_JQ="$(mktemp)"
trap 'rm -f "$TMP_PEOPLE" "$TMP_INTERACTIONS" "$TMP_JQ"' EXIT

people_count=0
for f in "$PEOPLE_DIR"/*.md; do
  [ -e "$f" ] || continue
  people_count=$((people_count + 1))
done

if [ "$people_count" -eq 0 ]; then
  : > "$TMP_PEOPLE"
else
  # Single awk invocation across every people/*.md, sorted for determinism.
  # Extracts: slug, tier (frontmatter), open_threads (bullet count under the
  # '## Open threads' section, top-level bullets only — lines starting with
  # "- " at column 0; wrapped continuation lines are not separately counted).
  for f in $(ls "$PEOPLE_DIR"/*.md | sort); do
    printf '%s\n' "$f"
  done | awk '
    function flush() {
      if (slug == "") return
      printf "{\"slug\":\"%s\",\"tier\":", slug
      if (tier == "") printf "null"
      else printf "\"%s\"", tier
      printf ",\"open_threads\":%d}\n", open_threads
    }
    {
      file = $0
      slug = file
      sub(/^.*\//, "", slug)
      sub(/\.md$/, "", slug)
      tier = ""
      open_threads = 0
      section = ""
      while ((getline line < file) > 0) {
        if (line ~ /^tier: /) {
          val = line
          sub(/^tier: */, "", val)
          tier = val
          continue
        }
        if (line ~ /^## Open threads/) { section = "open_threads"; continue }
        if (line ~ /^## /) { section = ""; continue }
        if (section == "open_threads" && line ~ /^- /) { open_threads++ }
      }
      close(file)
      flush()
    }
  ' > "$TMP_PEOPLE"
fi

if [ -d "$INTERACTIONS_DIR" ] && [ -n "$(ls -A "$INTERACTIONS_DIR"/*.md 2>/dev/null)" ]; then
  # Single awk invocation across every interactions/*.md. Extracts: id
  # (filename stem), date, calendar (bool, from calendar-event), people
  # (list of participant slugs), owners (list of commitment-bullet owners —
  # "user" or a participant slug; "_none_" bullets contribute nothing).
  for f in $(ls "$INTERACTIONS_DIR"/*.md | sort); do
    printf '%s\n' "$f"
  done | awk '
    function flush() {
      if (id == "") return
      printf "{\"id\":\"%s\",\"date\":\"%s\",\"calendar\":%s,\"people\":[", id, date, calendar
      for (i = 1; i <= peoplecount; i++) {
        if (i > 1) printf ","
        printf "\"%s\"", people[i]
      }
      printf "],\"owners\":["
      for (i = 1; i <= ownercount; i++) {
        if (i > 1) printf ","
        printf "\"%s\"", owners[i]
      }
      printf "]}\n"
    }
    {
      file = $0
      id = file
      sub(/^.*\//, "", id)
      sub(/\.md$/, "", id)
      date = ""
      calendar = "false"
      peoplecount = 0
      ownercount = 0
      delete people
      delete owners
      section = ""
      while ((getline line < file) > 0) {
        if (line ~ /^date: /) {
          val = line
          sub(/^date: */, "", val)
          date = val
          continue
        }
        if (line ~ /^calendar-event: /) {
          val = line
          sub(/^calendar-event: */, "", val)
          if (val != "null" && val != "") calendar = "true"
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
        if (line ~ /^## Commitments/) { section = "commitments"; continue }
        if (line ~ /^## /) { section = ""; continue }
        if (section == "commitments" && line ~ /^- /) {
          owner = line
          sub(/^- */, "", owner)
          colon = index(owner, ":")
          if (colon > 0) owner = substr(owner, 1, colon - 1)
          gsub(/^[ \t]+/, "", owner)
          gsub(/[ \t]+$/, "", owner)
          if (owner == "_none_") continue
          if (owner ~ /^\[\[[a-z0-9-]+\]\]$/) {
            owner = substr(owner, 3, length(owner) - 4)
          } else if (owner != "user") {
            continue
          }
          ownercount++
          owners[ownercount] = owner
        }
      }
      close(file)
      flush()
    }
  ' > "$TMP_INTERACTIONS"
else
  : > "$TMP_INTERACTIONS"
fi

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$TMP_JQ" <<'JQ_EOF'
($people) as $ppl
| ($interactions) as $ints
| (reduce $ints[] as $int (
    {};
    reduce $int.people[] as $slug (
      .;
      .[$slug] = ((.[$slug] // {touchpoints: 0, interactions: [], commit_user: 0, commit_them: 0})
        | .touchpoints += 1
        | .interactions += [{
            id: $int.id,
            date: $int.date,
            calendar: $int.calendar,
            others: ($int.people - [$slug])
          }]
        | .commit_user += ([$int.owners[] | select(. == "user")] | length)
      )
    )
  )) as $byPerson
| (reduce $ints[] as $int (
    $byPerson;
    reduce $int.owners[] as $owner (
      .;
      if $owner == "user" then .
      elif has($owner) then .[$owner].commit_them += 1
      else . end
    )
  )) as $withCommitThem
| {
    schema_version: "1.0.0",
    generated_at: $generated_at,
    people: (reduce $ppl[] as $p (
      {};
      .[$p.slug] = (
        ($withCommitThem[$p.slug].interactions // []) as $ilist
        | ($ilist | map(.date) | sort) as $dates
        | ($dates | length) as $n
        | {
            tier: $p.tier,
            touchpoints: ($withCommitThem[$p.slug].touchpoints // 0),
            first_interaction: (if $n == 0 then null else $dates[0] end),
            last_interaction: (if $n == 0 then null else $dates[-1] end),
            median_gap_days: (
              if $n < 2 then null
              else
                ([range(0; $n - 1) | (
                    ($dates[. + 1] | strptime("%Y-%m-%d") | mktime)
                    - ($dates[.] | strptime("%Y-%m-%d") | mktime)
                  ) / 86400] ) as $gaps
                | ($gaps | sort) as $sg
                | ($gaps | length) as $gn
                | (if ($gn % 2) == 1
                   then $sg[($gn - 1) / 2]
                   else ($sg[$gn / 2 - 1] + $sg[$gn / 2]) / 2
                   end) as $median
                | (($median + 0.5) | floor)
              end
            ),
            open_threads: $p.open_threads,
            commitments: {
              user: ($withCommitThem[$p.slug].commit_user // 0),
              them: ($withCommitThem[$p.slug].commit_them // 0)
            },
            interactions: ($ilist | sort_by(.date, .id) | reverse)
          }
      )
    ))
  }
JQ_EOF

jq -n \
  --slurpfile people "$TMP_PEOPLE" \
  --slurpfile interactions "$TMP_INTERACTIONS" \
  --arg generated_at "$GENERATED_AT" \
  -f "$TMP_JQ" | jq -S '.' > "$STATS_PATH"

echo "stats for ${people_count} people → ${STATS_PATH}"
