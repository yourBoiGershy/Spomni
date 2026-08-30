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
#   RA_EVAL_RERUN_FAILED=1 filter every manifest's case lines down to only
#                          those cases whose most recent recorded outcome
#                          (in <manifest-dir>/.last-run.tsv, see "State
#                          file" below) was FAIL, ERROR, or XPASS — plus any
#                          case with no recorded outcome at all (never run
#                          before, so it can't be silently skipped).
#                          Composes with RA_EVAL_SMOKE as an intersection
#                          (both filters apply). If a manifest has no
#                          .last-run.tsv yet, that manifest's filter is
#                          skipped entirely (all its cases run) and a
#                          `SUITE NOTE:` names it — a missing state file
#                          fails open to a full run, never to silently
#                          running nothing. If, after filtering, zero cases
#                          remain across every manifest, the suite prints
#                          `SUITE NOTE: nothing to re-run — last recorded
#                          run has no failures` and exits 0 (a success
#                          state, distinct from the empty-manifest exit-2
#                          error below).
#
# State file (<manifest-dir>/.last-run.tsv): after every non-dry-run
# invocation, eval-suite.sh records each dispatched case's outcome next to
# its manifest, one row per case: `<case-rel-path><TAB><OUTCOME><TAB>
# <iso8601-timestamp>`. A full run (no RA_EVAL_SMOKE, no
# RA_EVAL_RERUN_FAILED, or one that happens to include every one of that
# manifest's lines anyway) rewrites that manifest's whole state file; a
# filtered run (smoke and/or rerun-failed actually excluded some lines)
# updates only the rows for cases it actually dispatched, leaving every
# other row untouched. A case skipped by the cost cap (`reason=cost-cap`)
# is not evidence of anything and never overwrites its previous recorded
# outcome — if it has no previous recorded outcome either, no row is
# written for it at all. RA_EVAL_DRY_RUN=1 never touches state files
# (dry-run records nothing).
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
#      never fail the suite on their own); also the "nothing to re-run"
#      state under RA_EVAL_RERUN_FAILED=1 (see above) — a success state,
#      not the zero-cases error below.
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
RERUN_FAILED="${RA_EVAL_RERUN_FAILED:-0}"
DRY_RUN="${RA_EVAL_DRY_RUN:-0}"

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
CASE_MANIFEST_FILE="$(mktemp "${TMPDIR:-/tmp}/ra-eval-suite-case-manifests.XXXXXX")"
cleanup_cases_file() {
  rm -f "$CASES_FILE" "$CASE_MANIFEST_FILE"
}
trap cleanup_cases_file EXIT

# Per-manifest bookkeeping (parallel indexed arrays, bash 3.2-safe) used
# both to decide the RA_EVAL_RERUN_FAILED filter and, later, whether a
# manifest's .last-run.tsv gets a wholesale rewrite or a partial merge.
MANIFEST_REL_LIST=()
MANIFEST_STATE_PATH=()
MANIFEST_FULL_COUNT=()
MANIFEST_INCLUDED_COUNT=()

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

  MANIFEST_DIR="$(cd "$(dirname "$MANIFEST_PATH")" && pwd)"
  STATE_PATH="$MANIFEST_DIR/.last-run.tsv"

  MANIFEST_REL_LIST+=("$m")
  MANIFEST_STATE_PATH+=("$STATE_PATH")

  RERUN_STATE_MISSING=0
  if [ "$RERUN_FAILED" = "1" ] && [ ! -f "$STATE_PATH" ]; then
    RERUN_STATE_MISSING=1
    echo "SUITE NOTE: RA_EVAL_RERUN_FAILED=1 but no recorded run state for manifest: ${m} (expected ${STATE_PATH}) — running all its cases" >&2
  fi

  # Per line: strip everything from the first '#' onward (this handles
  # both full-line comments, whose stripped remainder is blank and thus
  # dropped below, and an inline trailing `# smoke` tag on an otherwise
  # live case line), trim surrounding whitespace, THEN treat the tag text
  # (if any) as the smoke marker.
  MANIFEST_LINE_COUNT=0
  MANIFEST_FULL_LINE_COUNT=0
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

    MANIFEST_FULL_LINE_COUNT=$((MANIFEST_FULL_LINE_COUNT + 1))

    tag_trimmed="$(printf '%s' "$tag_part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ "$SMOKE_ONLY" = "1" ] && [ "$tag_trimmed" != "smoke" ]; then
      continue
    fi

    if [ "$RERUN_FAILED" = "1" ] && [ "$RERUN_STATE_MISSING" -eq 0 ]; then
      prev_outcome="$(awk -F'\t' -v p="$path_part" '$1==p{print $2; exit}' "$STATE_PATH")"
      case "$prev_outcome" in
        FAIL|ERROR|XPASS|'') : ;;   # last FAIL/ERROR/XPASS, or never recorded -> include
        *) continue ;;              # PASS/XFAIL/SKIP -> already green (or not a failure); skip
      esac
    fi

    printf '%s\n' "$path_part" >> "$CASES_FILE"
    printf '%s\n' "$m" >> "$CASE_MANIFEST_FILE"
    MANIFEST_LINE_COUNT=$((MANIFEST_LINE_COUNT + 1))
    TOTAL_LINES=$((TOTAL_LINES + 1))
  done < "$MANIFEST_PATH"

  MANIFEST_INCLUDED_COUNT+=("$MANIFEST_LINE_COUNT")
  MANIFEST_FULL_COUNT+=("$MANIFEST_FULL_LINE_COUNT")

  if [ "$SMOKE_ONLY" = "1" ] && [ "$MANIFEST_LINE_COUNT" -eq 0 ]; then
    echo "SUITE NOTE: no smoke-tagged (# smoke) cases in manifest: ${m}" >&2
  fi
done

if [ "$TOTAL_LINES" -eq 0 ]; then
  if [ "$RERUN_FAILED" = "1" ]; then
    echo "SUITE NOTE: nothing to re-run — last recorded run has no failures" >&2
    exit 0
  fi
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

# write_state_files: records each dispatched case's outcome into its
# manifest's <manifest-dir>/.last-run.tsv (see header comment for the
# format and wholesale-vs-merge rule). Never called under
# RA_EVAL_DRY_RUN=1 (dry-run records nothing). Reads CASE_LIST,
# CASE_MANIFEST, CASE_OUTCOME, CASE_COST_SKIPPED, TOTAL_CASES, and the
# MANIFEST_* arrays populated during manifest resolution.
write_state_files() {
  RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  n_manifests="${#MANIFEST_REL_LIST[@]}"
  mi=0
  while [ "$mi" -lt "$n_manifests" ]; do
    m_rel="${MANIFEST_REL_LIST[$mi]}"
    state_path="${MANIFEST_STATE_PATH[$mi]}"

    wholesale=0
    if [ "${MANIFEST_INCLUDED_COUNT[$mi]}" -eq "${MANIFEST_FULL_COUNT[$mi]}" ]; then
      wholesale=1
    fi

    new_tmp="$(mktemp "${TMPDIR:-/tmp}/ra-eval-state.XXXXXX")"

    if [ "$wholesale" -eq 1 ] || [ ! -f "$state_path" ]; then
      : > "$new_tmp"
    else
      cp "$state_path" "$new_tmp"
    fi

    # Merge mode only: drop rows for cases this manifest is about to
    # rewrite fresh below, so the fresh row replaces (not duplicates) the
    # old one. No-op when new_tmp started empty (wholesale, or no prior
    # state file).
    if [ "$wholesale" -eq 0 ] && [ -s "$new_tmp" ]; then
      ci=0
      while [ "$ci" -lt "$TOTAL_CASES" ]; do
        if [ "${CASE_MANIFEST[$ci]}" = "$m_rel" ] && [ "${CASE_COST_SKIPPED[$ci]}" != "1" ]; then
          c_path="${CASE_LIST[$ci]}"
          awk -F'\t' -v p="$c_path" '$1!=p' "$new_tmp" > "${new_tmp}.f"
          mv "${new_tmp}.f" "$new_tmp"
        fi
        ci=$((ci + 1))
      done
    fi

    # Fresh rows for every case this manifest actually dispatched this run
    # (cost-cap skips are excluded — see below).
    ci=0
    while [ "$ci" -lt "$TOTAL_CASES" ]; do
      if [ "${CASE_MANIFEST[$ci]}" = "$m_rel" ] && [ "${CASE_COST_SKIPPED[$ci]}" != "1" ]; then
        printf '%s\t%s\t%s\n' "${CASE_LIST[$ci]}" "${CASE_OUTCOME[$ci]}" "$RUN_TS" >> "$new_tmp"
      fi
      ci=$((ci + 1))
    done

    # Wholesale mode only: a cost-cap-skipped case is not evidence, but if
    # this manifest previously had a recorded outcome for it, carry that
    # row forward unchanged rather than dropping it from a full rewrite.
    if [ "$wholesale" -eq 1 ] && [ -f "$state_path" ]; then
      ci=0
      while [ "$ci" -lt "$TOTAL_CASES" ]; do
        if [ "${CASE_MANIFEST[$ci]}" = "$m_rel" ] && [ "${CASE_COST_SKIPPED[$ci]}" = "1" ]; then
          c_path="${CASE_LIST[$ci]}"
          prev_row="$(awk -F'\t' -v p="$c_path" '$1==p{print; exit}' "$state_path")"
          if [ -n "$prev_row" ]; then
            printf '%s\n' "$prev_row" >> "$new_tmp"
          fi
        fi
        ci=$((ci + 1))
      done
    fi

    mkdir -p "$(dirname "$state_path")"
    mv "$new_tmp" "$state_path"

    mi=$((mi + 1))
  done
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
CASE_MANIFEST=()
while IFS= read -r manifest_line; do
  CASE_MANIFEST+=("$manifest_line")
done < "$CASE_MANIFEST_FILE"
TOTAL_CASES="${#CASE_LIST[@]}"

# Per-case outcome/cost-skip bookkeeping for the .last-run.tsv state files
# written after dispatch (see write_state_files below). Indices match
# CASE_LIST/CASE_MANIFEST throughout.
CASE_OUTCOME=()
CASE_COST_SKIPPED=()

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
      CASE_OUTCOME[$j]="SKIP"
      CASE_COST_SKIPPED[$j]=1
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

    CASE_OUTCOME[$w]="$OUTCOME"
    CASE_COST_SKIPPED[$w]=0

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

if [ "$DRY_RUN" != "1" ]; then
  write_state_files
fi

TOTAL_COST_FMT="$(python3 -c "print('%.2f' % float('$TOTAL_COST'))")"

echo "SUITE SUMMARY: pass=${PASS_N} fail=${FAIL_N} xfail=${XFAIL_N} xpass=${XPASS_N} skip=${SKIP_N} error=${ERROR_N} total_cost_usd=${TOTAL_COST_FMT}"

if [ "$FAIL_N" -eq 0 ] && [ "$XPASS_N" -eq 0 ] && [ "$ERROR_N" -eq 0 ]; then
  exit 0
else
  exit 1
fi
