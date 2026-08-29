#!/bin/bash
# eval-suite.sh — manifest runner for eval cases, per
# packages/core/contracts/eval-case.md.
#
# Usage: eval-suite.sh [suite.txt ...]
#
# Reads one or more suite.txt manifests (default: all three known
# manifests — packages/query/evals/suite.txt, packages/ingestion/evals/
# suite.txt, packages/attention/evals/suite.txt — if no args are given).
# For each non-comment, non-blank line (a repo-relative case directory),
# reads the case's prompt.md frontmatter `tier` and dispatches to
# eval-run.sh (tier: agent) or eval-run-skill.sh (tier: skill). Captures
# each case's mandatory `RESULT ...` line, tallies outcomes, sums
# cost_usd, enforces a suite-wide cost cap, and prints a final summary.
#
# Env overrides (passed through to the runners unchanged — this script
# does not read or alter them beyond forwarding the ambient environment,
# which every child process inherits automatically):
#   RA_EVAL_DRY_RUN=1      print the claude invocation instead of running it.
#                          eval-run-skill.sh emits its own
#                          `RESULT SKIP reason=dry-run` line in this mode;
#                          eval-run.sh's dry-run path prints only the
#                          command and exits with NO RESULT line at all —
#                          this script synthesizes the same
#                          `RESULT SKIP reason=dry-run` line in that case
#                          so both tiers behave identically from the
#                          suite's point of view.
#   RA_EVAL_FORCE=1        forces skill-tier cases to run even if they
#                          declare `runnable-when` (see eval-run-skill.sh).
#   RA_EVAL_TIMEOUT_SECS   wall-clock guard forwarded to both runners.
#
# eval-suite.sh's own knob:
#   RA_EVAL_MAX_COST_USD   suite-wide cost cap in USD (default 2.00). The
#                          running total is checked after each case; once
#                          exceeded, remaining cases are not dispatched —
#                          each is marked `RESULT SKIP reason=cost-cap`.
#
# Exit codes:
#   0  fail=0 AND xpass=0 AND error=0 (SKIPs, including cost-cap SKIPs,
#      never fail the suite on their own)
#   1  fail>0 OR xpass>0 OR error>0
#   2  a named manifest was not found, or every manifest resolved to zero
#      runnable case lines (silence about a broken manifest is never a
#      valid outcome)
#
# Portable to bash 3.2 (macOS default): no associative arrays, no
# mapfile, no [[ ]], no timeout(1). python3 is used for float math only.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RUN_AGENT="$SCRIPT_DIR/eval-run.sh"
RUN_SKILL="$SCRIPT_DIR/eval-run-skill.sh"

MAX_COST_USD="${RA_EVAL_MAX_COST_USD:-2.00}"

# ---------------------------------------------------------------------------
# Manifest resolution
# ---------------------------------------------------------------------------

DEFAULT_MANIFESTS="packages/query/evals/suite.txt packages/ingestion/evals/suite.txt packages/attention/evals/suite.txt"

if [ "$#" -ge 1 ]; then
  MANIFEST_ARGS="$*"
else
  MANIFEST_ARGS="$DEFAULT_MANIFESTS"
fi

CASES_FILE="$(mktemp "${TMPDIR:-/tmp}/ra-eval-suite-cases.XXXXXX")"
cleanup_cases_file() {
  rm -f "$CASES_FILE"
}
trap cleanup_cases_file EXIT

TOTAL_LINES=0
for m in $MANIFEST_ARGS; do
  case "$m" in
    /*) MANIFEST_PATH="$m" ;;
    *) MANIFEST_PATH="$REPO_ROOT/$m" ;;
  esac

  if [ ! -f "$MANIFEST_PATH" ]; then
    echo "SUITE ERROR: manifest not found: ${m} (resolved to ${MANIFEST_PATH})" >&2
    exit 2
  fi

  # Non-comment, non-blank lines only.
  MANIFEST_CASES="$(grep -v '^[[:space:]]*#' "$MANIFEST_PATH" | grep -v '^[[:space:]]*$')"
  if [ -n "$MANIFEST_CASES" ]; then
    printf '%s\n' "$MANIFEST_CASES" >> "$CASES_FILE"
    LINE_COUNT="$(printf '%s\n' "$MANIFEST_CASES" | wc -l | tr -d ' ')"
    TOTAL_LINES=$((TOTAL_LINES + LINE_COUNT))
  fi
done

if [ "$TOTAL_LINES" -eq 0 ]; then
  echo "SUITE ERROR: no runnable case lines found across manifest(s): ${MANIFEST_ARGS}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Frontmatter tier lookup (mirrors eval-run-skill.sh's parsing approach)
# ---------------------------------------------------------------------------

read_tier() {
  # $1 = prompt.md path -> prints the `tier` frontmatter value, or nothing.
  file="$1"
  fm_end="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$file" 2>/dev/null)"
  if [ -z "$fm_end" ]; then
    return 1
  fi
  awk -v end="$fm_end" 'NR>1 && NR<end && $0 ~ /^tier:/ { sub(/^tier:[ \t]*/, ""); print; exit }' "$file"
}

# add_cost: $1 = running total, $2 = new value (may be empty/None/non-numeric)
add_cost() {
  python3 -c "
import sys
total = float(sys.argv[1])
try:
    v = float(sys.argv[2])
except Exception:
    v = 0.0
print('%.6f' % (total + v))
" "$1" "$2"
}

cost_over_cap() {
  # $1 = running total, $2 = cap -> prints 1 if over, else 0
  python3 -c "
import sys
print(1 if float(sys.argv[1]) > float(sys.argv[2]) else 0)
" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Dispatch loop
# ---------------------------------------------------------------------------

PASS_N=0
FAIL_N=0
XFAIL_N=0
XPASS_N=0
SKIP_N=0
ERROR_N=0
TOTAL_COST="0.00"
COST_CAP_HIT=0

while IFS= read -r case_rel; do
  [ -n "$case_rel" ] || continue
  CASE_NAME="$(basename "$case_rel")"

  if [ "$COST_CAP_HIT" -eq 1 ]; then
    RESULT_LINE="RESULT SKIP case=${CASE_NAME} reason=cost-cap"
    echo "$RESULT_LINE"
    SKIP_N=$((SKIP_N + 1))
    continue
  fi

  case "$case_rel" in
    /*) CASE_ABS="$case_rel" ;;
    *) CASE_ABS="$REPO_ROOT/$case_rel" ;;
  esac

  if [ ! -d "$CASE_ABS" ]; then
    RESULT_LINE="RESULT ERROR case=${CASE_NAME} reason=\"case directory not found: ${case_rel}\""
    echo "$RESULT_LINE"
    ERROR_N=$((ERROR_N + 1))
    continue
  fi

  PROMPT_FILE="$CASE_ABS/prompt.md"
  if [ ! -f "$PROMPT_FILE" ]; then
    RESULT_LINE="RESULT ERROR case=${CASE_NAME} reason=\"missing prompt.md\""
    echo "$RESULT_LINE"
    ERROR_N=$((ERROR_N + 1))
    continue
  fi

  TIER="$(read_tier "$PROMPT_FILE")"

  case "$TIER" in
    agent) RUNNER="$RUN_AGENT" ;;
    skill) RUNNER="$RUN_SKILL" ;;
    *)
      RESULT_LINE="RESULT ERROR case=${CASE_NAME} reason=\"unknown or missing tier: ${TIER}\""
      echo "$RESULT_LINE"
      ERROR_N=$((ERROR_N + 1))
      continue
      ;;
  esac

  RUNNER_OUTPUT="$("$RUNNER" "$CASE_ABS" 2>&1)"

  RESULT_LINE="$(printf '%s\n' "$RUNNER_OUTPUT" | grep '^RESULT ' | tail -1)"

  if [ -z "$RESULT_LINE" ]; then
    # Silence must be impossible. eval-run.sh's dry-run path prints only
    # the command and exits 0 with no RESULT line at all; treat that as
    # the same dry-run SKIP eval-run-skill.sh would have emitted. Any
    # other silent runner exit is an infra error.
    if [ "${RA_EVAL_DRY_RUN:-0}" = "1" ]; then
      RESULT_LINE="RESULT SKIP case=${CASE_NAME} reason=dry-run"
    else
      RESULT_LINE="RESULT ERROR case=${CASE_NAME} reason=\"runner produced no RESULT line\""
    fi
  fi

  echo "$RESULT_LINE"

  OUTCOME="$(printf '%s\n' "$RESULT_LINE" | sed -n 's/^RESULT \([A-Z]*\).*/\1/p')"
  COST="$(printf '%s\n' "$RESULT_LINE" | sed -n 's/.*cost_usd=\([^ ]*\).*/\1/p')"

  case "$OUTCOME" in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)) ;;
    XFAIL) XFAIL_N=$((XFAIL_N + 1)) ;;
    XPASS) XPASS_N=$((XPASS_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
    ERROR) ERROR_N=$((ERROR_N + 1)) ;;
    *) ERROR_N=$((ERROR_N + 1)) ;;
  esac

  TOTAL_COST="$(add_cost "$TOTAL_COST" "$COST")"

  if [ "$(cost_over_cap "$TOTAL_COST" "$MAX_COST_USD")" = "1" ]; then
    COST_CAP_HIT=1
    echo "SUITE NOTE: cost cap exceeded (total_cost_usd=${TOTAL_COST} > RA_EVAL_MAX_COST_USD=${MAX_COST_USD}) — remaining cases will be skipped" >&2
  fi
done < "$CASES_FILE"

TOTAL_COST_FMT="$(python3 -c "print('%.2f' % float('$TOTAL_COST'))")"

echo "SUITE SUMMARY: pass=${PASS_N} fail=${FAIL_N} xfail=${XFAIL_N} xpass=${XPASS_N} skip=${SKIP_N} error=${ERROR_N} total_cost_usd=${TOTAL_COST_FMT}"

if [ "$FAIL_N" -eq 0 ] && [ "$XPASS_N" -eq 0 ] && [ "$ERROR_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
