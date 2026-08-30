#!/usr/bin/env bash
# bench-cold-start.sh — the measured source for ROADMAP Goal 4's cold-start
# target: from an empty temp dir, time (a) a shallow clone of the machinery
# repo, (b) the first who-next-direct.sh answer on a store, (c) both
# together, against the targets (clone->answer cold <= 15s, warm <= 5s).
#
# Plan 09's cold-start row. Plan 38 owns bench-retrieval.sh; when that lands
# this script's stages should be folded in as rows there and this file
# retired.
#
# Usage: bench-cold-start.sh [<store-dir>] [--remote <git-url-or-local-path>]
#                             [--runs K] [--json] [--warm]
#
# <store-dir> default: packages/core/fixtures/store (repo-relative). Never
# written to (who-next-direct.sh is read-only; it scratch-copies itself if
# index.json/stats.json are missing).
#
# --remote default: this checkout's own path (offline/CI-safe). Pass a real
# git URL (e.g. https://github.com/yourBoiGershy/Spomni.git) to measure the
# real network clone.
#
# Stages, best of --runs (default 2), timed via bash+perl (Time::HiRes,
# sub-second) or python3 as a fallback, else whole-second `date +%s`:
#   clone       shallow clone (git clone -q --depth 1 --single-branch) into
#               a fresh mktemp dir
#   answer      who-next-direct.sh run from the freshly cloned copy against
#               <store-dir>, --mode all --limit 20
#   total       clone + answer
#   warm-answer (only with --warm) a second who-next-direct.sh run on the
#               same clone; target <= 5s
#
# Output (default): a header line, then a markdown table
# `| stage | seconds | target | verdict |`. --json emits
# {"store":..., "remote":..., "rows":[{"stage":"clone","seconds":1.25},...]}
# instead.
#
# Exit 0 whenever the bench ran (a missed target is reported, not failed --
# this is a measurement, not a gate); exit 2 on bad args / missing git.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
QUERY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${QUERY_DIR}/../.." && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [<store-dir>] [--remote <git-url-or-local-path>]
                          [--runs K] [--json] [--warm]

Times a shallow clone of the machinery repo plus the first
who-next-direct.sh answer against <store-dir> (default:
packages/core/fixtures/store), against the ROADMAP Goal 4 cold-start
targets (clone->answer <= 15s, warm answer <= 5s). --remote defaults to
this checkout (offline/CI-safe); pass a real git URL to measure the network
clone. --runs K = best of K timed runs per stage (default 2). --warm adds a
second who-next-direct.sh run on the same clone.
EOF
  exit 2
}

STORE_DIR="${REPO_ROOT}/packages/core/fixtures/store"
REMOTE="$REPO_ROOT"
RUNS=2
JSON_OUT=0
WARM=0
STORE_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      [ "$#" -ge 2 ] || usage
      REMOTE="$2"
      shift 2
      ;;
    --runs)
      [ "$#" -ge 2 ] || usage
      RUNS="$2"
      shift 2
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --warm)
      WARM=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      usage
      ;;
    *)
      if [ "$STORE_SET" -eq 0 ]; then
        STORE_DIR="$1"
        STORE_SET=1
      else
        usage
      fi
      shift
      ;;
  esac
done

case "$RUNS" in
  ''|*[!0-9]*) usage ;;
esac
if [ "$RUNS" -lt 1 ]; then
  usage
fi

if [ ! -d "$STORE_DIR" ]; then
  echo "bench-cold-start.sh: no such store dir '$STORE_DIR'" >&2
  exit 2
fi
if [ ! -d "${STORE_DIR}/people" ]; then
  echo "bench-cold-start.sh: '$STORE_DIR' has no people/ subdir" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || {
  echo "bench-cold-start.sh: git is required" >&2
  exit 2
}
if [ "$JSON_OUT" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || {
    echo "bench-cold-start.sh: jq is required for --json output" >&2
    exit 2
  }
fi

PEOPLE_COUNT="$(find "${STORE_DIR}/people" -name '*.md' 2>/dev/null | wc -l | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Sub-second timing helper (mirrors bench-retrieval.sh)
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

# time_cmd_best_of <cmd...>
# Sets TIMING_RESULT to the best (lowest) elapsed seconds across $RUNS runs.
# Fails loudly (non-zero exit propagated) if any run of the command fails.
time_cmd_best_of() {
  best=""
  i=1
  while [ "$i" -le "$RUNS" ]; do
    start="$(now_s)"
    "$@" >/tmp/bench-cold-start-out.$$ 2>/tmp/bench-cold-start-err.$$
    status=$?
    end="$(now_s)"
    if [ "$status" -ne 0 ]; then
      echo "bench-cold-start.sh: command failed (exit $status): $*" >&2
      cat /tmp/bench-cold-start-err.$$ >&2
      rm -f /tmp/bench-cold-start-out.$$ /tmp/bench-cold-start-err.$$
      exit 1
    fi
    elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", (e - s) }')"
    if [ -z "$best" ] || awk -v a="$elapsed" -v b="$best" 'BEGIN { exit !(a < b) }'; then
      best="$elapsed"
    fi
    i=$((i + 1))
  done
  rm -f /tmp/bench-cold-start-out.$$ /tmp/bench-cold-start-err.$$
  TIMING_RESULT="$best"
}

# ---------------------------------------------------------------------------
# Stage: clone (fresh mktemp dir per run, best of $RUNS)
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-cold-start.XXXXXX")"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

CLONE_DIR="${WORKDIR}/machinery"

clone_once() {
  rm -rf "$CLONE_DIR"
  git clone -q --depth 1 --single-branch "$REMOTE" "$CLONE_DIR"
}

time_cmd_best_of clone_once
CLONE_S="$TIMING_RESULT"

WHO_NEXT_CLONED="${CLONE_DIR}/packages/query/scripts/who-next-direct.sh"
if [ ! -f "$WHO_NEXT_CLONED" ]; then
  echo "bench-cold-start.sh: cloned checkout missing packages/query/scripts/who-next-direct.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Stage: answer (first who-next-direct.sh run, from the cloned copy)
# ---------------------------------------------------------------------------

answer_once() {
  bash "$WHO_NEXT_CLONED" "$STORE_DIR" --mode all --limit 20 >/dev/null
}

time_cmd_best_of answer_once
ANSWER_S="$TIMING_RESULT"

TOTAL_S="$(awk -v c="$CLONE_S" -v a="$ANSWER_S" 'BEGIN { printf "%.2f", c + a }')"

# ---------------------------------------------------------------------------
# Stage: warm-answer (optional)
# ---------------------------------------------------------------------------

WARM_ANSWER_S=""
if [ "$WARM" -eq 1 ]; then
  time_cmd_best_of answer_once
  WARM_ANSWER_S="$TIMING_RESULT"
fi

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------

verdict() {
  # verdict <seconds> <target>
  awk -v s="$1" -v t="$2" 'BEGIN { print (s <= t) ? "ok" : "over" }'
}

TOTAL_VERDICT="$(verdict "$TOTAL_S" 15)"
WARM_VERDICT=""
if [ "$WARM" -eq 1 ]; then
  WARM_VERDICT="$(verdict "$WARM_ANSWER_S" 5)"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ "$JSON_OUT" -eq 1 ]; then
  if [ "$WARM" -eq 1 ]; then
    jq -n \
      --arg store "$STORE_DIR" \
      --argjson people "$PEOPLE_COUNT" \
      --arg remote "$REMOTE" \
      --arg clone "$CLONE_S" \
      --arg answer "$ANSWER_S" \
      --arg total "$TOTAL_S" \
      --arg total_verdict "$TOTAL_VERDICT" \
      --arg warm_answer "$WARM_ANSWER_S" \
      --arg warm_verdict "$WARM_VERDICT" \
      '{
        store: $store,
        people: $people,
        remote: $remote,
        rows: [
          {stage: "clone", seconds: ($clone | tonumber)},
          {stage: "answer", seconds: ($answer | tonumber)},
          {stage: "total", seconds: ($total | tonumber), target: 15, verdict: $total_verdict},
          {stage: "warm-answer", seconds: ($warm_answer | tonumber), target: 5, verdict: $warm_verdict}
        ]
      }'
  else
    jq -n \
      --arg store "$STORE_DIR" \
      --argjson people "$PEOPLE_COUNT" \
      --arg remote "$REMOTE" \
      --arg clone "$CLONE_S" \
      --arg answer "$ANSWER_S" \
      --arg total "$TOTAL_S" \
      --arg total_verdict "$TOTAL_VERDICT" \
      '{
        store: $store,
        people: $people,
        remote: $remote,
        rows: [
          {stage: "clone", seconds: ($clone | tonumber)},
          {stage: "answer", seconds: ($answer | tonumber)},
          {stage: "total", seconds: ($total | tonumber), target: 15, verdict: $total_verdict}
        ]
      }'
  fi
else
  echo "cold-start bench — store=${STORE_DIR} people=${PEOPLE_COUNT} remote=${REMOTE}"
  echo ""
  echo "| stage | seconds | target | verdict |"
  echo "|---|---|---|---|"
  echo "| clone | ${CLONE_S} | - | - |"
  echo "| answer | ${ANSWER_S} | - | - |"
  echo "| total (clone+answer) | ${TOTAL_S} | <= 15s | ${TOTAL_VERDICT} |"
  if [ "$WARM" -eq 1 ]; then
    echo "| warm-answer | ${WARM_ANSWER_S} | <= 5s | ${WARM_VERDICT} |"
  fi
fi
