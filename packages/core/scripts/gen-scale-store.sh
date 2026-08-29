#!/bin/bash
# gen-scale-store.sh — generate an UNCOMMITTED synthetic store at scale, for
# performance runs (packages/core/contracts/{person,interaction,wakeup}.md).
#
# Usage: gen-scale-store.sh <target-dir> [people-count]   (people-count defaults to 1000)
#
# Generates a contract-valid synthetic store into <target-dir>: one
# people/<slug>.md per person (deterministic pseudo-random name/org/role/
# location/tags/tier from seed lists, no real people), ~10
# interactions/<id>.md per person, and a handful of wakeups/<id>.md. Refuses
# to write into an existing non-empty directory. Prints a summary on
# success.
#
# This output is never committed — point it at a scratch/temp dir and
# delete it when done. Portable to bash 3.2 (macOS default): no associative
# arrays, no mapfile.

set -eu

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <target-dir> [people-count]

Generates a contract-valid synthetic store (people, interactions, wakeups)
into <target-dir>. people-count defaults to 1000. Refuses to write into an
existing non-empty directory.
EOF
  exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi

TARGET_DIR="$1"
PEOPLE_COUNT="${2:-1000}"

case "$PEOPLE_COUNT" in
  ''|*[!0-9]*)
    echo "gen-scale-store.sh: people-count must be a positive integer, got '${PEOPLE_COUNT}'" >&2
    exit 1
    ;;
esac
if [ "$PEOPLE_COUNT" -lt 1 ]; then
  echo "gen-scale-store.sh: people-count must be >= 1" >&2
  exit 1
fi

if [ -e "$TARGET_DIR" ]; then
  if [ ! -d "$TARGET_DIR" ]; then
    echo "gen-scale-store.sh: ${TARGET_DIR} exists and is not a directory" >&2
    exit 1
  fi
  if [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    echo "gen-scale-store.sh: refusing to write into existing non-empty directory ${TARGET_DIR}" >&2
    exit 1
  fi
fi

mkdir -p "$TARGET_DIR/people" "$TARGET_DIR/interactions" "$TARGET_DIR/wakeups"

start_ts=$(date +%s)

# ---------------------------------------------------------------------------
# Seed lists (synthetic only — see docs/DECISIONS.md#code-data-separation).
# ---------------------------------------------------------------------------

FIRST_NAMES="Alex Jordan Sam Taylor Morgan Casey Riley Avery Quinn Rowan
Skyler Dana Reese Jamie Devon Harper Emerson Kai Sage Blair
Elliot Finley Marlowe Nico Wren Frankie Shay Remy Tatum Indigo
Yael Zora Mira Oren Talia Bram Isla Cove Juno Lior
Vesper Ansel Briar Corin Delta Eowyn Fable Gideon Halcyon Ives"

LAST_NAMES="Reyes Nakamura Petrov Osei Kowalski Fontaine Haddad Larsen Mbeki Choudhury
Delgado Ferreira Andersson Silva Novak Okafor Brennan Ivanov Castillo Whitfield
Solis Bergstrom Nakagawa Duarte Fischer Adeyemi Voss Kessler Marchetti Solheim
Tanaka Volkov Ekwueme Alonso Dubois Renner Kallas Vance Iyer Boone
Amundsen Cardoza Pham Sørensen Grigori Halvorsen Okonkwo Beaumont Wexler Zimmer"

ORGS="Meridian Fintech;Cascade Cloud;Vega Textiles;Kestrel Robotics;Orbital Labs
Fernbank Capital;Vantage Financial;Kite Logistics;Bright Path Foundation;Vertex Ventures
Lumen Pay;Ironclad Supply Co.;Summit Advisory Partners;Redline Consulting;Nordkreis Media
Fernway Logistics;Brightline Health;Solstice Health;Fielding & Cross;Casa Fuentes"

ROLES="Software Engineer;Product Manager;VP of Partnerships;Director of Engineering;Founder & CEO
Head of Product;Sales Lead;Research Scientist;Marketing Director;Operations Manager
Principal Consultant;Design Lead;Data Scientist;General Counsel;Chief of Staff
Investor;Nonprofit Director;Architect;High School Teacher;Physician"

LOCATIONS="New York, NY;San Francisco, CA;Austin, TX;Seattle, WA;Chicago, IL
Boston, MA;Denver, CO;Portland, OR;Berlin, Germany;Prague, Czech Republic
Mexico City, Mexico;Lagos, Nigeria;Tokyo, Japan;Oslo, Norway;Dublin, Ireland
Barcelona, Spain;Nairobi, Kenya;Bangalore, India;Istanbul, Turkey;San Diego, CA"

TAG_SETS="work,colleague;business,sales;founder,startup;friend,art;college-friend
family,cousin;nonprofit,mentor;business,investor;work,healthtech;childhood-friend
fintech,business;work,mentor;founder,logistics;friend,food;family-friend"

TIERS="inner-circle close active dormant"

HOW_MET="Met at a work conference;Cold intro through a mutual contact;Former coworkers;College roommates
Introduced by a mutual friend;Met on a panel;Grew up in the same neighborhood;Met through a mentorship program"

# Split a "|"-free space list into a positional array-ish string via eval-free indexing.
nth_word() {
  # $1 = space-separated words, $2 = zero-based index
  printf '%s\n' "$1" | tr -s '\n' ' ' | awk -v n="$2" '{print $(n+1)}'
}

nth_semi() {
  # $1 = ";"-separated / newline-separated list, $2 = zero-based index
  printf '%s\n' "$1" | tr -s '\n' ';' | awk -F';' -v n="$2" '{
    # rebuild array from all fields (tr merged newlines to ;)
    c=0
    for (i=1;i<=NF;i++) { if ($i != "") { c++; if (c-1==n) { print $i; exit } } }
  }'
}

kebab() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

FIRST_COUNT=$(printf '%s\n' "$FIRST_NAMES" | tr -s '[:space:]' '\n' | grep -c .)
LAST_COUNT=$(printf '%s\n' "$LAST_NAMES" | tr -s '[:space:]' '\n' | grep -c .)
ORG_COUNT=$(printf '%s\n' "$ORGS" | tr -s '\n' ';' | tr -s ';' '\n' | grep -c .)
ROLE_COUNT=$(printf '%s\n' "$ROLES" | tr -s '\n' ';' | tr -s ';' '\n' | grep -c .)
LOC_COUNT=$(printf '%s\n' "$LOCATIONS" | tr -s '\n' ';' | tr -s ';' '\n' | grep -c .)
TAG_COUNT=$(printf '%s\n' "$TAG_SETS" | tr -s '\n' ';' | tr -s ';' '\n' | grep -c .)
TIER_COUNT=$(printf '%s\n' "$TIERS" | tr -s '[:space:]' '\n' | grep -c .)
HOWMET_COUNT=$(printf '%s\n' "$HOW_MET" | tr -s '\n' ';' | tr -s ';' '\n' | grep -c .)

TODAY=$(date +%Y-%m-%d)

# ISO date `n` days before today, portable across BSD/GNU date.
days_ago() {
  n="$1"
  if date -v-1d >/dev/null 2>&1; then
    date -v-"${n}"d +%Y-%m-%d
  else
    date -d "-${n} days" +%Y-%m-%d
  fi
}

# ISO date `n` days after today, portable across BSD/GNU date.
days_from_now() {
  n="$1"
  if date -v+1d >/dev/null 2>&1; then
    date -v+"${n}"d +%Y-%m-%d
  else
    date -d "+${n} days" +%Y-%m-%d
  fi
}

people_written=0
interactions_written=0
wakeups_written=0

i=0
while [ "$i" -lt "$PEOPLE_COUNT" ]; do
  first_idx=$(( i % FIRST_COUNT ))
  last_idx=$(( (i / FIRST_COUNT) % LAST_COUNT ))
  org_idx=$(( (i * 3) % ORG_COUNT ))
  role_idx=$(( (i * 5) % ROLE_COUNT ))
  loc_idx=$(( (i * 7) % LOC_COUNT ))
  tag_idx=$(( (i * 11) % TAG_COUNT ))
  tier_idx=$(( i % TIER_COUNT ))
  howmet_idx=$(( (i * 13) % HOWMET_COUNT ))

  first=$(nth_word "$FIRST_NAMES" "$first_idx")
  last=$(nth_word "$LAST_NAMES" "$last_idx")
  name="${first} ${last}"
  slug=$(kebab "$name")

  org=$(nth_semi "$ORGS" "$org_idx")
  role=$(nth_semi "$ROLES" "$role_idx")
  loc=$(nth_semi "$LOCATIONS" "$loc_idx")
  tags=$(nth_semi "$TAG_SETS" "$tag_idx")
  tier=$(nth_word "$TIERS" "$tier_idx")
  howmet=$(nth_semi "$HOW_MET" "$howmet_idx")

  last_touch=$(days_ago 3)

  person_file="$TARGET_DIR/people/${slug}.md"
  {
    printf -- '---\n'
    printf 'schema_version: 1.0.0\n'
    printf 'name: %s\n' "$name"
    printf 'org: %s\n' "$org"
    printf 'role: %s\n' "$role"
    printf 'location: %s\n' "$loc"
    printf 'tags: [%s]\n' "$tags"
    printf 'how-met: %s\n' "$howmet"
    printf 'last-touch: %s\n' "$last_touch"
    printf 'tier: %s\n' "$tier"
    printf -- '---\n\n'
    printf '## Facts\n\n'
    printf -- '- **[told-by-user]** Working on a project at %s worth checking in on (%s)\n\n' "$org" "$last_touch"
    printf '## Open threads\n\n'
    printf -- '- Follow up on how things are going at %s.\n\n' "$org"
    printf '## Personal details\n\n'
    printf 'Synthetic fixture person generated for scale testing; no real biography.\n'
  } > "$person_file"
  people_written=$((people_written + 1))

  k=1
  while [ "$k" -le 10 ]; do
    offset=$(( k * 17 + (i % 5) ))
    idate=$(days_ago "$offset")
    idfile="${idate}-${slug}--${k}"
    src="scale-${i}-${k}"
    interaction_file="$TARGET_DIR/interactions/${idfile}.md"
    {
      printf -- '---\n'
      printf 'schema_version: 1.0.0\n'
      printf 'date: %s\n' "$idate"
      printf 'people: ["[[%s]]"]\n' "$slug"
      printf 'calendar-event: null\n'
      printf 'source-capture: %s\n' "$src"
      printf -- '---\n\n'
      printf '## Summary\n\n'
      printf 'Synthetic logged touchpoint %s with %s, generated for scale testing.\n\n' "$k" "$name"
      printf '## Commitments\n\n'
      if [ $(( k % 2 )) -eq 0 ]; then
        printf -- '- user: follow up with %s [by %s]\n' "$name" "$TODAY"
      else
        printf -- '- _none_\n'
      fi
    } > "$interaction_file"
    interactions_written=$((interactions_written + 1))
    k=$((k + 1))
  done

  # One standing wake-up per 50 people, spread across the queue.
  if [ $(( i % 50 )) -eq 0 ]; then
    due=$(days_from_now 14)
    wakeup_id="${due}-${slug}"
    wakeup_file="$TARGET_DIR/wakeups/${wakeup_id}.md"
    {
      printf -- '---\n'
      printf 'schema_version: 1.0.0\n'
      printf 'id: %s\n' "$wakeup_id"
      printf 'due: %s\n' "$due"
      printf 'people: ["[[%s]]"]\n' "$slug"
      printf 'why: "synthetic standing check-in for scale testing"\n'
      printf 'status: pending\n'
      printf 'origin: standing\n'
      printf 'source-signal: null\n'
      printf -- '---\n\n'
      printf '## Context\n\n'
      printf 'Synthetic wake-up for %s, generated for scale testing.\n' "$name"
    } > "$wakeup_file"
    wakeups_written=$((wakeups_written + 1))
  fi

  i=$((i + 1))
done

end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

echo "gen-scale-store.sh: generated synthetic store at ${TARGET_DIR}"
echo "  people:       ${people_written}"
echo "  interactions: ${interactions_written}"
echo "  wakeups:      ${wakeups_written}"
echo "  elapsed:      ${elapsed}s"
