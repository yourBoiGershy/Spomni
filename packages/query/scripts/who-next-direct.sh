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

# --- per-person frontmatter/body extraction ------------------------------
#
# One awk pass over every people/*.md file (instead of the old ~5 process
# spawns per person: two awk/sed calls for frontmatter fields, two more for
# the Facts/Open threads/Personal details sections, and two jq calls to
# pull the index/stats entries) emits one JSONL line per slug with the
# raw per-file fields (name, frontmatter tier, facts[], open_threads_text,
# personal). A single follow-up jq call then joins those lines against
# index.json and stats.json (via --slurpfile) to build the same per-person
# object shape the unchanged filter/rank jq program below consumes. Files
# are fed to awk in ascending slug order so tie-breaking in the final
# stable sort matches the old behaviour byte-for-byte; only slugs present
# in index.json as an object survive the join (mirrors the old loop, which
# iterated index.json's keys and skipped missing files).

TMP_RAW="$(mktemp)"
TMP_AWK="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_AWK"' EXIT

PEOPLE_FILE_NAMES="$(cd "$PEOPLE_DIR" && ls -1 *.md 2>/dev/null | sort)"

PEOPLE_FILES=()
if [ -n "$PEOPLE_FILE_NAMES" ]; then
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    PEOPLE_FILES+=("${PEOPLE_DIR}/${fn}")
  done <<PEOPLE_FILE_LIST
$PEOPLE_FILE_NAMES
PEOPLE_FILE_LIST
fi

if [ "${#PEOPLE_FILES[@]}" -gt 0 ]; then
  awk '
    function esc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      gsub(/\r/, "", s)
      gsub(/\t/, "\\t", s)
      return s
    }
    function flush(   i, out, ot, pers) {
      if (started != 1) return
      out = "{\"slug\":\"" esc(slug) "\",\"name\":\"" esc(name) "\",\"tier\":\"" esc(fmtier) "\",\"facts\":["
      for (i = 1; i <= nfacts; i++) {
        if (i > 1) out = out ","
        out = out "\"" esc(facts[i]) "\""
      }
      out = out "]"
      ot = ""
      for (i = 1; i <= nopen; i++) {
        if (i > 1) ot = ot "; "
        ot = ot openarr[i]
      }
      pers = ""
      for (i = 1; i <= npers; i++) {
        if (i > 1) pers = pers " "
        pers = pers persarr[i]
      }
      out = out ",\"open_threads_text\":\"" esc(ot) "\",\"personal\":\"" esc(pers) "\"}"
      print out
    }
    FNR == 1 {
      flush()
      started = 1
      slug = FILENAME
      sub(/^.*\//, "", slug)
      sub(/\.md$/, "", slug)
      fm_c = 0; name = ""; fmtier = ""; name_found = 0; tier_found = 0
      nfacts = 0; nopen = 0; npers = 0; insec = ""
    }
    /^---$/ { fm_c++; next }
    fm_c == 1 {
      if (!name_found && $0 ~ /^name: */) { v = $0; sub(/^name: */, "", v); name = v; name_found = 1 }
      if (!tier_found && $0 ~ /^tier: */) { v = $0; sub(/^tier: */, "", v); fmtier = v; tier_found = 1 }
    }
    $0 == "## Facts" { insec = "facts"; next }
    $0 == "## Open threads" { insec = "open"; next }
    $0 == "## Personal details" { insec = "personal"; next }
    /^## / { insec = ""; next }
    insec == "facts" && /^- / {
      v = $0; sub(/^- /, "", v)
      if (length(v) > 0) { nfacts++; facts[nfacts] = v }
    }
    insec == "open" && /^- / {
      v = $0; sub(/^- /, "", v)
      nopen++; openarr[nopen] = v
    }
    insec == "personal" && NF > 0 { npers++; persarr[npers] = $0 }
    END { flush() }
  ' "${PEOPLE_FILES[@]}" > "$TMP_AWK"
else
  : > "$TMP_AWK"
fi

if [ -s "$TMP_AWK" ]; then
  jq -c -s \
    --slurpfile idx "$INDEX_JSON" \
    --slurpfile st "$STATS_JSON" \
    --arg today "$TODAY" \
    '
    ($idx[0]) as $idxmap
    | (($st[0].people) // {}) as $stmap
    | .[]
    | ($idxmap[.slug]) as $ie
    | select($ie != null and ($ie | type) == "object")
    | ($stmap[.slug] // {}) as $se
    | {
        slug: .slug,
        name: (if .name == "" then .slug else .name end),
        tags: ($ie.tags // []),
        kind: ($ie.kind // null),
        last_interaction: ($se.last_interaction // $ie["last-touch"] // null),
        touchpoints: ($se.touchpoints // 0),
        open_threads: ($se.open_threads // 0),
        commitments_user: ($se.commitments.user // 0),
        tier: ($se.tier // (if .tier == "" then null else .tier end)),
        facts: .facts,
        personal: .personal,
        open_threads_text: .open_threads_text,
        today: $today
      }
    ' "$TMP_AWK" > "$TMP_RAW"
else
  : > "$TMP_RAW"
fi

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
