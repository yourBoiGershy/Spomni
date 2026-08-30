#!/usr/bin/env bash
# bench-retrieval.sh — read-only retrieval-speed benchmark, the single
# measured source for docs/plans/2026-08-30-38-retrieval-speed.md §1
# (baseline) and §2 (targets)/the wave-3 regression guard.
#
# Usage: bench-retrieval.sh <store-dir> [--json] [--scale N] [--runs K]
#
# Times every §1 row on a SCRATCH COPY of <store-dir> (or a generated
# N-person store when --scale is given, in which case <store-dir> is
# optional) — it never writes into the given store:
#
#   1. build-index.sh          full run   (packages/core/scripts/)
#   2. build-stats.sh          full run   (packages/core/scripts/)
#   3. validate-store.sh       full run   (packages/core/scripts/)
#   4. who-next-direct.sh      index+stats fresh
#   5. who-next-direct.sh      index/stats missing (deleted from the copy)
#   6. MCP server cold start -> initialize, store copy FRESH
#   7. MCP server cold start -> initialize, store copy STALE
#   8. warm per-tool latency (median of 20): search_people, get_person,
#      suggest_reachouts, upcoming_meetings
#
# Rows 1-5 are timed via bash+perl (Time::HiRes, sub-second) or python3 as a
# fallback, best of --runs (default 2). Rows 6-8 are timed via
# bench-mcp-client.mjs, skipped with "skipped (no node)" if
# packages/query/server/node_modules is missing or node < 22.6.
#
# --scale N: generates a synthetic N-person store via
# packages/core/scripts/gen-scale-store.sh into scratch, builds index+stats
# into it, and benches that instead of (or in addition to) <store-dir>.
#
# Output: a markdown table `| surface | condition | seconds |` to stdout,
# preceded by a header line with people/interactions counts. --json emits
# one JSON object instead: {store, people, interactions, rows: [...],
# tools: {...}}.
#
# Exit 0 on success; exit 2 with a usage message on bad args.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
QUERY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${QUERY_DIR}/../.." && pwd)"
CORE_SCRIPTS_DIR="${REPO_ROOT}/packages/core/scripts"
WHO_NEXT_SCRIPT="${QUERY_DIR}/scripts/who-next-direct.sh"
SERVER_DIR="${QUERY_DIR}/server"
MCP_CLIENT="${SCRIPT_DIR}/bench-mcp-client.mjs"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <store-dir> [--json] [--scale N] [--runs K] [--guard]

Times every row of docs/plans/2026-08-30-38-retrieval-speed.md's §1 table on
a scratch copy of <store-dir> (never writes into it). --scale N generates
and benches an N-person synthetic store instead (in that case <store-dir>
is optional). --runs K = best of K timed runs per row (default 2). --guard
compares every row against the plan's fixture-store (30-person) regression
thresholds and exits 1 with a GUARD FAIL line per miss, plus a process-count
check on build-index.sh / who-next-direct.sh.
EOF
  exit 2
}

STORE_DIR=""
JSON_OUT=0
SCALE_N=""
RUNS=2
GUARD=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_OUT=1
      shift
      ;;
    --guard)
      GUARD=1
      shift
      ;;
    --scale)
      [ "$#" -ge 2 ] || usage
      SCALE_N="$2"
      shift 2
      ;;
    --runs)
      [ "$#" -ge 2 ] || usage
      RUNS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      usage
      ;;
    *)
      if [ -z "$STORE_DIR" ]; then
        STORE_DIR="$1"
      else
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$STORE_DIR" ] && [ -z "$SCALE_N" ]; then
  usage
fi

case "$RUNS" in
  ''|*[!0-9]*) usage ;;
esac
if [ "$RUNS" -lt 1 ]; then
  usage
fi

if [ -n "$SCALE_N" ]; then
  case "$SCALE_N" in
    ''|*[!0-9]*) usage ;;
  esac
fi

if [ -n "$STORE_DIR" ] && [ -z "$SCALE_N" ]; then
  if [ ! -d "$STORE_DIR" ]; then
    echo "bench-retrieval.sh: no such store dir '$STORE_DIR'" >&2
    exit 2
  fi
  if [ ! -d "${STORE_DIR}/people" ]; then
    echo "bench-retrieval.sh: '$STORE_DIR' has no people/ subdir" >&2
    exit 2
  fi
fi

command -v jq >/dev/null 2>&1 || {
  echo "bench-retrieval.sh: jq is required" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Sub-second timing helper: prints elapsed seconds (2 decimals) for a
# command, best of $RUNS runs. Uses perl Time::HiRes if available, else
# python3, else falls back to whole-second `date +%s`.
# ---------------------------------------------------------------------------

now_s() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'print time'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.time())'
  else
    date +%s
  fi
}

# time_cmd_best_of <label> -- <cmd...>
# Sets TIMING_RESULT to the best (lowest) elapsed seconds across $RUNS runs.
# Fails loudly (non-zero exit propagated) if any run of the command fails.
time_cmd_best_of() {
  best=""
  i=1
  while [ "$i" -le "$RUNS" ]; do
    start="$(now_s)"
    "$@" >/tmp/bench-retrieval-out.$$ 2>/tmp/bench-retrieval-err.$$
    status=$?
    end="$(now_s)"
    if [ "$status" -ne 0 ]; then
      echo "bench-retrieval.sh: command failed (exit $status): $*" >&2
      cat /tmp/bench-retrieval-err.$$ >&2
      rm -f /tmp/bench-retrieval-out.$$ /tmp/bench-retrieval-err.$$
      exit 1
    fi
    elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", (e - s) }')"
    if [ -z "$best" ] || awk -v a="$elapsed" -v b="$best" 'BEGIN { exit !(a < b) }'; then
      best="$elapsed"
    fi
    i=$((i + 1))
  done
  rm -f /tmp/bench-retrieval-out.$$ /tmp/bench-retrieval-err.$$
  TIMING_RESULT="$best"
}

# ---------------------------------------------------------------------------
# Scratch store setup — cp -Rp, never touching the given store-dir
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-retrieval.XXXXXX")"
export SPOMNI_CACHE_DIR="${WORKDIR}/cache"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

SRC_FOR_COPY="$STORE_DIR"

if [ -n "$SCALE_N" ]; then
  SCALE_DIR="${WORKDIR}/scale"
  bash "${CORE_SCRIPTS_DIR}/gen-scale-store.sh" "$SCALE_DIR" "$SCALE_N" >&2
  SRC_FOR_COPY="$SCALE_DIR"
fi

SCRATCH="${WORKDIR}/scratch"
mkdir -p "$SCRATCH"
for entry in people interactions wakeups index.json stats.json profile.md user-model.md; do
  if [ -e "${SRC_FOR_COPY}/${entry}" ]; then
    cp -Rp "${SRC_FOR_COPY}/${entry}" "${SCRATCH}/${entry}"
  fi
done

PEOPLE_COUNT="$(find "${SCRATCH}/people" -name '*.md' 2>/dev/null | wc -l | awk '{print $1}')"
INTERACTIONS_COUNT="$(find "${SCRATCH}/interactions" -name '*.md' 2>/dev/null | wc -l | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Rows 1-3: build-index.sh, build-stats.sh, validate-store.sh (full)
# ---------------------------------------------------------------------------

# build-index.sh / build-stats.sh already write <store>/index.json and
# <store>/stats.json themselves (their stdout is just a one-line summary) —
# time them in place, no redirect/mv (a prior version clobbered the JSON
# files with that summary line, breaking every row downstream).
time_cmd_best_of bash "${CORE_SCRIPTS_DIR}/build-index.sh" "$SCRATCH"
BUILD_INDEX_S="$TIMING_RESULT"

time_cmd_best_of bash "${CORE_SCRIPTS_DIR}/build-stats.sh" "$SCRATCH"
BUILD_STATS_S="$TIMING_RESULT"

time_cmd_best_of bash "${CORE_SCRIPTS_DIR}/validate-store.sh" "$SCRATCH"
VALIDATE_STORE_S="$TIMING_RESULT"

# ---------------------------------------------------------------------------
# Row 4: who-next-direct.sh, index+stats fresh
# ---------------------------------------------------------------------------

time_cmd_best_of bash "$WHO_NEXT_SCRIPT" "$SCRATCH" --mode all --limit 20
WHO_NEXT_FRESH_S="$TIMING_RESULT"

# ---------------------------------------------------------------------------
# Row 5: who-next-direct.sh, index/stats missing
# ---------------------------------------------------------------------------

MISSING_DIR="${WORKDIR}/missing"
mkdir -p "$MISSING_DIR"
for entry in people interactions wakeups; do
  if [ -e "${SCRATCH}/${entry}" ]; then
    cp -Rp "${SCRATCH}/${entry}" "${MISSING_DIR}/${entry}"
  fi
done
time_cmd_best_of bash "$WHO_NEXT_SCRIPT" "$MISSING_DIR" --mode all --limit 20
WHO_NEXT_MISSING_S="$TIMING_RESULT"

# ---------------------------------------------------------------------------
# Rows 6-8: MCP cold start (fresh/stale) + warm tool latency
# ---------------------------------------------------------------------------

NODE_OK=1
if [ ! -d "${SERVER_DIR}/node_modules" ]; then
  NODE_OK=0
fi
if command -v node >/dev/null 2>&1; then
  NODE_VER_OK="$(node -e '
    const [maj, min] = process.versions.node.split(".").map(Number);
    process.stdout.write((maj > 22 || (maj === 22 && min >= 6)) ? "1" : "0");
  ' 2>/dev/null || echo 0)"
  if [ "$NODE_VER_OK" != "1" ]; then
    NODE_OK=0
  fi
else
  NODE_OK=0
fi

MCP_COLD_FRESH_S="skipped (no node)"
MCP_COLD_STALE_S="skipped (no node)"
TOOL_SEARCH_MS="skipped (no node)"
TOOL_GET_PERSON_MS="skipped (no node)"
TOOL_SUGGEST_MS="skipped (no node)"
TOOL_UPCOMING_MS="skipped (no node)"
# Set non-zero when an MCP row fails outright (client crash / bad JSON) so
# the script still prints its table (and --json) but exits 1 at the end,
# rather than aborting before any output is produced.
MCP_FAILED=0

if [ "$NODE_OK" -eq 1 ]; then
  # Fresh cold start: scratch store copy already has fresh index/stats
  # (rebuilt above, mtimes newer than people/ since we just wrote them).
  FRESH_DIR="${WORKDIR}/mcp-fresh"
  cp -Rp "$SCRATCH" "$FRESH_DIR"
  # Ensure index/stats are newer than every people/interactions file.
  touch "${FRESH_DIR}/index.json" "${FRESH_DIR}/stats.json"

  FRESH_OUT=""
  if ! FRESH_OUT="$(node --experimental-strip-types "$MCP_CLIENT" "$FRESH_DIR" 20 2>/tmp/bench-retrieval-mcp-err.$$)"; then
    echo "bench-retrieval.sh: bench-mcp-client.mjs (fresh) failed:" >&2
    cat /tmp/bench-retrieval-mcp-err.$$ >&2
    MCP_FAILED=1
    MCP_COLD_FRESH_S="error"
    TOOL_SEARCH_MS="error"
    TOOL_GET_PERSON_MS="error"
    TOOL_SUGGEST_MS="error"
    TOOL_UPCOMING_MS="error"
  fi
  rm -f /tmp/bench-retrieval-mcp-err.$$

  if [ "$MCP_FAILED" -eq 0 ]; then
    MCP_COLD_FRESH_MS="$(echo "$FRESH_OUT" | jq -r '.cold_start_ms')"
    MCP_COLD_FRESH_S="$(awk -v ms="$MCP_COLD_FRESH_MS" 'BEGIN { printf "%.2f", ms / 1000 }')"
    TOOL_SEARCH_MS="$(echo "$FRESH_OUT" | jq -r '.tools.search_people')"
    TOOL_GET_PERSON_MS="$(echo "$FRESH_OUT" | jq -r '.tools.get_person')"
    TOOL_SUGGEST_MS="$(echo "$FRESH_OUT" | jq -r '.tools.suggest_reachouts')"
    TOOL_UPCOMING_MS="$(echo "$FRESH_OUT" | jq -r '.tools.upcoming_meetings')"
  fi

  # Stale cold start: touch one people/*.md so it is newer than index.json.
  STALE_DIR="${WORKDIR}/mcp-stale"
  cp -Rp "$SCRATCH" "$STALE_DIR"
  FIRST_PERSON="$(find "${STALE_DIR}/people" -name '*.md' | head -n 1)"
  if [ -n "$FIRST_PERSON" ]; then
    sleep 1
    touch "$FIRST_PERSON"
  fi

  STALE_OUT=""
  if ! STALE_OUT="$(node --experimental-strip-types "$MCP_CLIENT" "$STALE_DIR" 1 2>/tmp/bench-retrieval-mcp-err2.$$)"; then
    echo "bench-retrieval.sh: bench-mcp-client.mjs (stale) failed:" >&2
    cat /tmp/bench-retrieval-mcp-err2.$$ >&2
    MCP_FAILED=1
    MCP_COLD_STALE_S="error"
  fi
  rm -f /tmp/bench-retrieval-mcp-err2.$$

  if [ -n "$STALE_OUT" ]; then
    MCP_COLD_STALE_MS="$(echo "$STALE_OUT" | jq -r '.cold_start_ms')"
    MCP_COLD_STALE_S="$(awk -v ms="$MCP_COLD_STALE_MS" 'BEGIN { printf "%.2f", ms / 1000 }')"
  fi
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ "$JSON_OUT" -eq 1 ]; then
  jq -n \
    --arg store "${STORE_DIR:-<scale:$SCALE_N>}" \
    --argjson people "$PEOPLE_COUNT" \
    --argjson interactions "$INTERACTIONS_COUNT" \
    --arg build_index "$BUILD_INDEX_S" \
    --arg build_stats "$BUILD_STATS_S" \
    --arg validate_store "$VALIDATE_STORE_S" \
    --arg who_next_fresh "$WHO_NEXT_FRESH_S" \
    --arg who_next_missing "$WHO_NEXT_MISSING_S" \
    --arg mcp_cold_fresh "$MCP_COLD_FRESH_S" \
    --arg mcp_cold_stale "$MCP_COLD_STALE_S" \
    --arg search_people_ms "$TOOL_SEARCH_MS" \
    --arg get_person_ms "$TOOL_GET_PERSON_MS" \
    --arg suggest_reachouts_ms "$TOOL_SUGGEST_MS" \
    --arg upcoming_meetings_ms "$TOOL_UPCOMING_MS" \
    '{
      store: $store,
      people: $people,
      interactions: $interactions,
      rows: [
        {surface: "build-index.sh", condition: "full", seconds: $build_index},
        {surface: "build-stats.sh", condition: "full", seconds: $build_stats},
        {surface: "validate-store.sh", condition: "full", seconds: $validate_store},
        {surface: "who-next-direct.sh", condition: "index+stats fresh", seconds: $who_next_fresh},
        {surface: "who-next-direct.sh", condition: "index+stats missing", seconds: $who_next_missing},
        {surface: "mcp-cold-start", condition: "fresh", seconds: $mcp_cold_fresh},
        {surface: "mcp-cold-start", condition: "stale", seconds: $mcp_cold_stale}
      ],
      tools: {
        search_people_ms: $search_people_ms,
        get_person_ms: $get_person_ms,
        suggest_reachouts_ms: $suggest_reachouts_ms,
        upcoming_meetings_ms: $upcoming_meetings_ms
      }
    }'
else
  echo "# bench-retrieval: store=${STORE_DIR:-<scale:$SCALE_N>} people=${PEOPLE_COUNT} interactions=${INTERACTIONS_COUNT} runs=${RUNS}"
  echo ""
  echo "| surface | condition | seconds |"
  echo "|---|---|---|"
  echo "| build-index.sh | full | ${BUILD_INDEX_S} |"
  echo "| build-stats.sh | full | ${BUILD_STATS_S} |"
  echo "| validate-store.sh | full | ${VALIDATE_STORE_S} |"
  echo "| who-next-direct.sh | index+stats fresh | ${WHO_NEXT_FRESH_S} |"
  echo "| who-next-direct.sh | index+stats missing | ${WHO_NEXT_MISSING_S} |"
  echo "| mcp-cold-start | fresh | ${MCP_COLD_FRESH_S} |"
  echo "| mcp-cold-start | stale | ${MCP_COLD_STALE_S} |"
  echo "| search_people (warm, median ms) | any | ${TOOL_SEARCH_MS} |"
  echo "| get_person (warm, median ms) | any | ${TOOL_GET_PERSON_MS} |"
  echo "| suggest_reachouts (warm, median ms) | any | ${TOOL_SUGGEST_MS} |"
  echo "| upcoming_meetings (warm, median ms) | any | ${TOOL_UPCOMING_MS} |"
fi

# ---------------------------------------------------------------------------
# Exit status: any outright MCP row failure fails the run even without
# --guard (the caller still gets the printed table/JSON above first).
# ---------------------------------------------------------------------------

EXIT_CODE=0
if [ "$MCP_FAILED" -eq 1 ]; then
  EXIT_CODE=1
fi

# ---------------------------------------------------------------------------
# --guard: threshold check (fixture store, 30 people, x3 CI headroom) plus a
# deterministic process-count check (build-index.sh / who-next-direct.sh
# must spawn O(1) jq, not one per person).
# ---------------------------------------------------------------------------

if [ "$GUARD" -eq 1 ]; then
  echo "" >&2
  echo "=== guard checks ===" >&2

  guard_check() {
    # guard_check <row-label> <seconds-value> <limit>
    label="$1"
    value="$2"
    limit="$3"
    case "$value" in
      ''|*[!0-9.]*)
        echo "GUARD FAIL: $label $value (non-numeric — node/MCP unavailable or errored)" >&2
        GUARD_FAILED=1
        return
        ;;
    esac
    if awk -v v="$value" -v l="$limit" 'BEGIN { exit !(v > l) }'; then
      echo "GUARD FAIL: $label $value > $limit" >&2
      GUARD_FAILED=1
    else
      echo "GUARD PASS: $label $value <= $limit" >&2
    fi
  }

  GUARD_FAILED=0
  guard_check "build-index.sh" "$BUILD_INDEX_S" "1.0"
  guard_check "build-stats.sh" "$BUILD_STATS_S" "1.0"
  guard_check "validate-store.sh" "$VALIDATE_STORE_S" "3.0"
  guard_check "who-next-direct.sh fresh" "$WHO_NEXT_FRESH_S" "1.5"
  guard_check "who-next-direct.sh missing" "$WHO_NEXT_MISSING_S" "3.0"
  if [ "$NODE_OK" -eq 1 ]; then
    guard_check "mcp-cold-start fresh" "$MCP_COLD_FRESH_S" "1.5"
    guard_check "mcp-cold-start stale" "$MCP_COLD_STALE_S" "1.5"
  else
    echo "GUARD SKIP: mcp-cold-start fresh/stale (no node)" >&2
  fi

  # Process-count guard: build-index.sh and who-next-direct.sh must spawn
  # O(1) jq processes, not one per person. Re-run each under `bash -x` on
  # the (disposable, already-rebuilt) scratch copy and count trace lines
  # that invoke jq directly (`^\+.*jq `, i.e. a literal "+ ... jq " trace
  # line, not "+jq" as a variable name elsewhere).
  BUILD_INDEX_JQ_COUNT="$(bash -x "${CORE_SCRIPTS_DIR}/build-index.sh" "$SCRATCH" 2>&1 1>/dev/null | grep -c '^\+.*jq ' || true)"
  if [ "$BUILD_INDEX_JQ_COUNT" -le 3 ]; then
    echo "GUARD PASS: build-index.sh jq spawn count $BUILD_INDEX_JQ_COUNT <= 3" >&2
  else
    echo "GUARD FAIL: build-index.sh jq spawn count $BUILD_INDEX_JQ_COUNT > 3" >&2
    GUARD_FAILED=1
  fi

  WHO_NEXT_JQ_COUNT="$(bash -x "$WHO_NEXT_SCRIPT" "$SCRATCH" --mode all --limit 20 2>&1 1>/dev/null | grep -c '^\+.*jq ' || true)"
  if [ "$WHO_NEXT_JQ_COUNT" -le 3 ]; then
    echo "GUARD PASS: who-next-direct.sh jq spawn count $WHO_NEXT_JQ_COUNT <= 3" >&2
  else
    echo "GUARD FAIL: who-next-direct.sh jq spawn count $WHO_NEXT_JQ_COUNT > 3" >&2
    GUARD_FAILED=1
  fi

  if [ "$GUARD_FAILED" -eq 1 ]; then
    EXIT_CODE=1
  fi
fi

exit "$EXIT_CODE"
