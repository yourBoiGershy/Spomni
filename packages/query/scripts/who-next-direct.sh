#!/usr/bin/env bash
# who-next-direct.sh — zero-dependency (bash + jq) candidate-pool builder for
# the /who-next skill's fallback path, used when the spomni-query MCP server
# is unavailable (cold cloud/phone session: no npm ci + server boot needed).
#
# Usage: who-next-direct.sh <store-dir> [--mode friends|coffee|all]
#                            [--limit N] [--today YYYY-MM-DD]
#                            [--include-transactional]
#
# Reads index.json, stats.json and people/*.md straight from the store dir.
# If index.json/stats.json are missing, generates them via
# packages/core/scripts/build-index.sh / build-stats.sh into a scratch copy
# of the store under mktemp — the direct-read path never writes into the
# user's store (single-writer rule; query is read-only).
#
# kind: transactional (landlords, mail, closed one-offs) is dropped in
# coffee and all modes (friends mode already excludes it via its kind
# allowlist) unless --include-transactional is passed.
#
# Emits one JSON object per line on stdout (at most 20), per the contract in
# packages/query/skills/who-next/SKILL.md section 0. Exit 0 on success (even
# zero candidates); exit 2 with a one-line stderr message if people/ is
# missing or jq is not on PATH.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_SCRIPTS_DIR="${SCRIPT_DIR}/../../core/scripts"

MODE="all"
LIMIT=20
TODAY=""
STORE_DIR=""
INCLUDE_TRANSACTIONAL=0

usage() {
  cat <<'USAGE'
Usage: who-next-direct.sh <store-dir> [--mode friends|coffee|all]
                           [--limit N] [--today YYYY-MM-DD]
                           [--include-transactional]

Zero-dependency (bash + jq) fallback candidate-pool builder for /who-next,
used when the spomni-query MCP server is not available. Reads index.json,
stats.json and people/*.md from <store-dir> and emits one JSON object per
line on stdout (at most 20 lines, at most --limit).

Options:
  --mode friends|coffee|all   Filter mode (default: all)
  --limit N                   Max lines emitted (default: 20)
  --today YYYY-MM-DD          Override "today" for the 14-day/age math
                               (default: today's date)
  --include-transactional     Keep kind: transactional people (landlords,
                               mail, closed one-offs) — dropped by default
                               in coffee and all modes
  --help                      Show this help and exit

Read-only: never writes to <store-dir>. If index.json/stats.json are
missing, they are generated into a scratch mktemp copy of the store.
USAGE
}

# --- parse args ---------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    --include-transactional)
      INCLUDE_TRANSACTIONAL=1
      shift
      ;;
    -*)
      echo "who-next-direct.sh: unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$STORE_DIR" ]; then
        STORE_DIR="$1"
      else
        echo "who-next-direct.sh: unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$STORE_DIR" ]; then
  echo "who-next-direct.sh: missing required <store-dir> argument" >&2
  usage >&2
  exit 2
fi

case "$MODE" in
  friends|coffee|all) ;;
  *)
    echo "who-next-direct.sh: --mode must be friends, coffee, or all (got: ${MODE})" >&2
    exit 2
    ;;
esac

if [ -z "$TODAY" ]; then
  TODAY="$(date +%Y-%m-%d)"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "who-next-direct.sh: jq is required but not found on PATH" >&2
  exit 2
fi

if [ ! -d "${STORE_DIR}/people" ]; then
  echo "who-next-direct.sh: no people/ directory found at ${STORE_DIR}/people" >&2
  exit 2
fi

# --- locate or generate index.json / stats.json -------------------------
#
# If either is missing, never write into the caller's store: copy it into a
# scratch dir first, then build there.

READ_DIR="$STORE_DIR"

if [ ! -f "${STORE_DIR}/index.json" ] || [ ! -f "${STORE_DIR}/stats.json" ]; then
  SCRATCH_DIR="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH_DIR"' EXIT
  cp -R "${STORE_DIR}/." "${SCRATCH_DIR}/"
  [ -f "${SCRATCH_DIR}/index.json" ] || bash "${CORE_SCRIPTS_DIR}/build-index.sh" "$SCRATCH_DIR" >&2
  [ -f "${SCRATCH_DIR}/stats.json" ] || bash "${CORE_SCRIPTS_DIR}/build-stats.sh" "$SCRATCH_DIR" >&2
  READ_DIR="$SCRATCH_DIR"
fi

INDEX_JSON="${READ_DIR}/index.json"
STATS_JSON="${READ_DIR}/stats.json"
PEOPLE_DIR="${STORE_DIR}/people"

# --- per-person frontmatter/body extraction -----------------------------

extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

extract_field() {
  fm="$1"
  key="$2"
  printf '%s\n' "$fm" | sed -n "s/^${key}: *//p" | head -1
}

# Section bullets (lines "- ...") between "## <heading>" and the next "## ".
extract_section_bullets() {
  file="$1"
  heading="$2"
  awk -v h="$heading" '
    $0 == "## " h { insec=1; next }
    /^## / { insec=0 }
    insec && /^- / { sub(/^- /, ""); print }
  ' "$file"
}

# packages/ingestion/specs/currency.md "Consumers": drop an
# "unverified since D" open thread when D is older than the person's
# second-most-recent interaction date — it went stale before the touch
# before last, not just the latest one. Bare bullets and fresh "as-of"
# bullets (no "unverified since" marker) always pass through untouched.
# threshold="" (fewer than one prior interaction on file) keeps
# everything — staleness can't be judged without a second date.
filter_open_threads() {
  file="$1"
  heading="$2"
  threshold="$3"
  extract_section_bullets "$file" "$heading" | while IFS= read -r line; do
    unverified_date="$(printf '%s\n' "$line" | sed -n 's/.*unverified since \([0-9][0-9-]*\).*/\1/p')"
    if [ -n "$unverified_date" ] && [ -n "$threshold" ] && [[ "$unverified_date" < "$threshold" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done
}

# Prose lines (non-empty, non-bullet) between "## <heading>" and the next "## ".
extract_section_prose() {
  file="$1"
  heading="$2"
  awk -v h="$heading" '
    $0 == "## " h { insec=1; next }
    /^## / { insec=0 }
    insec && NF { print }
  ' "$file"
}

TMP_RAW="$(mktemp)"
trap 'rm -f "$TMP_RAW"' EXIT

for slug in $(jq -r 'to_entries[] | select(.value | type == "object") | .key' "$INDEX_JSON" | sort); do
  f="${PEOPLE_DIR}/${slug}.md"
  [ -f "$f" ] || continue

  fm="$(extract_frontmatter "$f")"
  name="$(extract_field "$fm" name)"
  fm_tier="$(extract_field "$fm" tier)"

  # [stale] facts (inferred-* provenance the derived writer has flagged,
  # per specs/currency.md) never surface as talking points.
  facts_json="$(extract_section_bullets "$f" "Facts" | grep -v '\[stale\]' | jq -R . | jq -s -c 'map(select(length > 0))')"
  personal_text="$(extract_section_prose "$f" "Personal details" | paste -sd' ' -)"

  index_entry="$(jq -c --arg slug "$slug" '.[$slug]' "$INDEX_JSON")"
  stats_entry="$(jq -c --arg slug "$slug" '.people[$slug] // {}' "$STATS_JSON")"
  # stats.json's interactions[] is sorted most-recent-first (build-stats.sh);
  # index 1 is the second-most-recent interaction date. Fewer than two
  # interactions on file -> threshold_date is empty, so nothing is dropped.
  threshold_date="$(printf '%s' "$stats_entry" | jq -r '(.interactions[1].date // empty)')"
  open_threads_text="$(filter_open_threads "$f" "Open threads" "$threshold_date" | paste -sd';' - | sed 's/;/; /g')"

  jq -n -c \
    --arg slug "$slug" \
    --arg name "$name" \
    --arg fm_tier "$fm_tier" \
    --arg today "$TODAY" \
    --arg open_threads_text "$open_threads_text" \
    --arg personal "$personal_text" \
    --argjson facts "$facts_json" \
    --argjson idx "$index_entry" \
    --argjson st "$stats_entry" \
    '{
      slug: $slug,
      name: (if $name == "" then $slug else $name end),
      tags: ($idx.tags // []),
      kind: ($idx.kind // null),
      last_interaction: ($st.last_interaction // $idx["last-touch"] // null),
      touchpoints: ($st.touchpoints // 0),
      open_threads: ($st.open_threads // 0),
      commitments_user: ($st.commitments.user // 0),
      tier: ($st.tier // (if $fm_tier == "" then null else $fm_tier end)),
      facts: $facts,
      personal: $personal,
      open_threads_text: $open_threads_text,
      today: $today
    }' >> "$TMP_RAW"
done

# --- filter, rank, limit -------------------------------------------------

jq -s -c \
  --arg mode "$MODE" \
  --argjson limit "$LIMIT" \
  --arg today "$TODAY" \
  --argjson include_transactional "$INCLUDE_TRANSACTIONAL" \
  '
  map(
    . + {
      days_since: (
        if .last_interaction == null then null
        else (
          (($today | strptime("%Y-%m-%d") | mktime)
            - (.last_interaction | strptime("%Y-%m-%d") | mktime)) / 86400
          | floor
        )
        end
      ),
      stub: (
        (.tags | index("name-from-email") != null)
        or ((.name | test(" ") | not) and (.facts | length) == 0)
      )
    }
  )
  # exclude people touched in the last 14 days
  | map(select(.days_since == null or .days_since >= 14))
  # coffee mode: exclude inbound LinkedIn pitches
  | map(select($mode != "coffee" or (.tags | index("linkedin-outreach") == null)))
  # coffee/all modes: drop kind: transactional (landlords, mail, closed
  # one-offs) unless --include-transactional was passed; friends mode
  # already excludes it via its kind allowlist below.
  | map(select(
      $include_transactional == 1
      or $mode == "friends"
      or .kind != "transactional"
    ))
  # friends mode: keep friend/family/null kind
  | map(select($mode != "friends" or (.kind == null or .kind == "friend" or .kind == "family")))
  | map(
      . + {
        rank_tier: (
          if (.open_threads > 0 or .commitments_user > 0) then 3
          elif .kind != null then 2
          else 1
          end
        )
      }
    )
  # stubs last, then rank_tier desc, then longer days_since first
  | sort_by([(if .stub then 1 else 0 end), -.rank_tier, -(.days_since // -1)])
  | .[0:$limit]
  | .[]
  | del(.today, .rank_tier)
  ' "$TMP_RAW"
