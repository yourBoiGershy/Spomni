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
# eval-suite.sh's own knobs:
#   RA_EVAL_MAX_COST_USD   suite-wide cost cap in USD (default 2.00). Cases
#                          are dispatched in waves of RA_EVAL_PARALLEL (see
#                          below); the running total is checked BETWEEN
#                          waves, once all of a wave's cases have reported.
#                          Once exceeded, remaining not-yet-dispatched cases
#                          are marked `RESULT SKIP reason=cost-cap` without
#                          running. Documented overshoot: up to one full
#                          wave of already-in-flight cases may run past the
#                          cap before it is checked, since cost is only
#                          knowable once a case's RESULT line is captured.
#   RA_EVAL_PARALLEL       number of cases to run concurrently per wave
#                          (default 4; must be >= 1). Each case in a wave
#                          runs as a background job with its full runner
#                          output captured to a private temp file; the
#                          suite waits for the whole wave, then parses each
#                          case's output IN MANIFEST ORDER (never
#                          interleaved) — RESULT extraction, dry-run
#                          synthesis, tallying, and cost summing are
#                          unchanged from the serial path. RA_EVAL_PARALLEL=1
#                          reproduces the prior strictly-serial behavior,
#                          including per-case (wave-of-one) cap checking.
#                          Parallel-safety precondition: both runners
#                          (eval-run.sh, eval-run-skill.sh) mktemp their own
#                          worked directory and copy the fixture store
#                          before touching it, so concurrent cases never
#                          share mutable state.
#   RA_EVAL_SMOKE=1        run only manifest lines carrying an inline
#                          trailing `# smoke` tag (see Suite manifest
#                          format below). A manifest with zero tagged lines
#                          under smoke mode prints `SUITE NOTE:` naming it
#                          and continues (silence is never valid); if every
#                          manifest yields zero smoke lines, the suite exits
#                          2 like the existing zero-cases path.
#
# Test hooks (override the runner script paths; default unchanged):
#   RA_EVAL_RUNNER_AGENT   absolute path replacing eval-run.sh.
#   RA_EVAL_RUNNER_SKILL   absolute path replacing eval-run-skill.sh.
#
# Suite manifest format: one repo-relative case directory per line;
# `#`-prefixed lines are full-line comments; a line may also carry an
# inline trailing `# smoke` tag (e.g. `packages/query/evals/cases/foo  #
# smoke`) marking it part of the smoke subset selected by RA_EVAL_SMOKE=1.
# Everything from the first `#` onward is stripped (and the remainder
# trimmed) before the path is resolved, so untagged and full-line-comment
# lines behave exactly as before.
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

RUN_AGENT="${RA_EVAL_RUNNER_AGENT:-$SCRIPT_DIR/eval-run.sh}"
RUN_SKILL="${RA_EVAL_RUNNER_SKILL:-$SCRIPT_DIR/eval-run-skill.sh}"

MAX_COST_USD="${RA_EVAL_MAX_COST_USD:-2.00}"
PARALLEL="${RA_EVAL_PARALLEL:-4}"
SMOKE_ONLY="${RA_EVAL_SMOKE:-0}"

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

  # Per line: strip everything from the first '#' onward (this handles
  # both full-line comments, whose stripped remainder is blank and thus
  # dropped below, and an inline trailing `# smoke` tag on an otherwise
  # live case line), trim surrounding whitespace, THEN treat the tag text
  # (if any) as the smoke marker.
  MANIFEST_LINE_COUNT=0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    case "$raw_line" in
      *'#'*)
        path_part="${raw_line%%#*}"
        tag_part="${raw_line#*#}"
        ;;
      *)
        path_part="$raw_line"
        tag_part=""
        ;;
    esac

    path_part="$(printf '%s' "$path_part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$path_part" ] || continue

    tag_trimmed="$(printf '%s' "$tag_part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ "$SMOKE_ONLY" = "1" ] && [ "$tag_trimmed" != "smoke" ]; then
      continue
    fi

    printf '%s\n' "$path_part" >> "$CASES_FILE"
    MANIFEST_LINE_COUNT=$((MANIFEST_LINE_COUNT + 1))
    TOTAL_LINES=$((TOTAL_LINES + 1))
  done < "$MANIFEST_PATH"

  if [ "$SMOKE_ONLY" = "1" ] && [ "$MANIFEST_LINE_COUNT" -eq 0 ]; then
    echo "SUITE NOTE: no smoke-tagged (# smoke) cases in manifest: ${m}" >&2
  fi
done

if [ "$TOTAL_LINES" -eq 0 ]; then
  if [ "$SMOKE_ONLY" = "1" ]; then
    echo "SUITE ERROR: no smoke-tagged case lines found across manifest(s): ${MANIFEST_ARGS}" >&2
  else
    echo "SUITE ERROR: no runnable case lines found across manifest(s): ${MANIFEST_ARGS}" >&2
  fi
  exit 2
fi

# Validate/clamp RA_EVAL_PARALLEL: must be a positive integer.
case "$PARALLEL" in
  ''|*[!0-9]*) PARALLEL=4 ;;
esac
if [ "$PARALLEL" -lt 1 ]; then
  PARALLEL=1
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
# Dispatch loop — wave-parallel
# ---------------------------------------------------------------------------
#
# Cases are loaded into an indexed array (plain bash 3.2 arrays are fine;
# only associative arrays are off-limits) and dispatched in waves of up to
# RA_EVAL_PARALLEL. Within a wave, each case's runner invocation is
# backgrounded with its combined stdout/stderr redirected to a private temp
# file under WAVE_DIR; `wait` blocks for the whole wave; then every case in
# the wave is parsed IN MANIFEST ORDER (RESULT extraction, dry-run
# synthesis, tallying, cost summing — identical to the old serial path) so
# RESULT lines are never interleaved regardless of finish order. The cost
# cap is evaluated once per wave, after all of that wave's cases have been
# parsed.

CASE_LIST=()
while IFS= read -r case_line; do
  CASE_LIST+=("$case_line")
done < "$CASES_FILE"
TOTAL_CASES="${#CASE_LIST[@]}"

WAVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ra-eval-suite-wave.XXXXXX")"
cleanup_wave_dir() {
  rm -rf "$WAVE_DIR"
}
trap 'cleanup_cases_file; cleanup_wave_dir' EXIT

PASS_N=0
FAIL_N=0
XFAIL_N=0
XPASS_N=0
SKIP_N=0
ERROR_N=0
TOTAL_COST="0.00"
COST_CAP_HIT=0

idx=0
while [ "$idx" -lt "$TOTAL_CASES" ]; do
  if [ "$COST_CAP_HIT" -eq 1 ]; then
    # Cap already tripped by an earlier wave: skip every remaining case
    # without dispatching any of them.
    j="$idx"
    while [ "$j" -lt "$TOTAL_CASES" ]; do
      case_rel="${CASE_LIST[$j]}"
      CASE_NAME="$(basename "$case_rel")"
      echo "RESULT SKIP case=${CASE_NAME} reason=cost-cap"
      SKIP_N=$((SKIP_N + 1))
      j=$((j + 1))
    done
    break
  fi

  wave_start="$idx"
  wave_end=$((idx + PARALLEL - 1))
  if [ "$wave_end" -ge "$TOTAL_CASES" ]; then
    wave_end=$((TOTAL_CASES - 1))
  fi

  # Per-case wave-local state, indexed by position within the wave.
  W_CASE_NAME=()
  W_OUT_FILE=()
  W_PID=()
  W_IMMEDIATE=()

  w="$wave_start"
  while [ "$w" -le "$wave_end" ]; do
    case_rel="${CASE_LIST[$w]}"
    CASE_NAME="$(basename "$case_rel")"
    IMMEDIATE_RESULT=""

    case "$case_rel" in
      /*) CASE_ABS="$case_rel" ;;
      *) CASE_ABS="$REPO_ROOT/$case_rel" ;;
    esac

    if [ ! -d "$CASE_ABS" ]; then
      IMMEDIATE_RESULT="RESULT ERROR case=${CASE_NAME} reason=\"case directory not found: ${case_rel}\""
    else
      PROMPT_FILE="$CASE_ABS/prompt.md"
      if [ ! -f "$PROMPT_FILE" ]; then
        IMMEDIATE_RESULT="RESULT ERROR case=${CASE_NAME} reason=\"missing prompt.md\""
      else
        TIER="$(read_tier "$PROMPT_FILE")"
        case "$TIER" in
          agent) RUNNER="$RUN_AGENT" ;;
          skill) RUNNER="$RUN_SKILL" ;;
          *)
            IMMEDIATE_RESULT="RESULT ERROR case=${CASE_NAME} reason=\"unknown or missing tier: ${TIER}\""
            ;;
        esac
      fi
    fi

    W_CASE_NAME+=("$CASE_NAME")

    if [ -n "$IMMEDIATE_RESULT" ]; then
      W_IMMEDIATE+=("$IMMEDIATE_RESULT")
      W_OUT_FILE+=("")
      W_PID+=("")
    else
      OUT_FILE="$WAVE_DIR/case_${w}.out"
      : > "$OUT_FILE"
      "$RUNNER" "$CASE_ABS" > "$OUT_FILE" 2>&1 &
      W_IMMEDIATE+=("")
      W_OUT_FILE+=("$OUT_FILE")
      W_PID+=("$!")
    fi

    w=$((w + 1))
  done

  # Block for every backgrounded runner in this wave (bash 3.2 has no
  # `wait -n`; a bare `wait` drains all current background jobs, which is
  # exactly this wave since we never dispatch the next one early).
  wait

  # Parse the wave's results in manifest order.
  w="$wave_start"
  wpos=0
  while [ "$w" -le "$wave_end" ]; do
    CASE_NAME="${W_CASE_NAME[$wpos]}"
    IMMEDIATE_RESULT="${W_IMMEDIATE[$wpos]}"

    if [ -n "$IMMEDIATE_RESULT" ]; then
      RESULT_LINE="$IMMEDIATE_RESULT"
    else
      OUT_FILE="${W_OUT_FILE[$wpos]}"
      RESULT_LINE="$(grep '^RESULT ' "$OUT_FILE" 2>/dev/null | tail -1)"

      if [ -z "$RESULT_LINE" ]; then
        # Silence must be impossible. eval-run.sh's dry-run path prints
        # only the command and exits 0 with no RESULT line at all; treat
        # that as the same dry-run SKIP eval-run-skill.sh would have
        # emitted. Any other silent runner exit is an infra error.
        if [ "${RA_EVAL_DRY_RUN:-0}" = "1" ]; then
          RESULT_LINE="RESULT SKIP case=${CASE_NAME} reason=dry-run"
        else
          RESULT_LINE="RESULT ERROR case=${CASE_NAME} reason=\"runner produced no RESULT line\""
        fi
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

    w=$((w + 1))
    wpos=$((wpos + 1))
  done

  if [ "$(cost_over_cap "$TOTAL_COST" "$MAX_COST_USD")" = "1" ]; then
    COST_CAP_HIT=1
    echo "SUITE NOTE: cost cap exceeded (total_cost_usd=${TOTAL_COST} > RA_EVAL_MAX_COST_USD=${MAX_COST_USD}) — remaining cases will be skipped" >&2
  fi

  idx=$((wave_end + 1))
done

TOTAL_COST_FMT="$(python3 -c "print('%.2f' % float('$TOTAL_COST'))")"

echo "SUITE SUMMARY: pass=${PASS_N} fail=${FAIL_N} xfail=${XFAIL_N} xpass=${XPASS_N} skip=${SKIP_N} error=${ERROR_N} total_cost_usd=${TOTAL_COST_FMT}"

if [ "$FAIL_N" -eq 0 ] && [ "$XPASS_N" -eq 0 ] && [ "$ERROR_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
