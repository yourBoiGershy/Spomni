#!/usr/bin/env bash
# check-golden.sh — deterministic differ that grades a filing run's worked
# store against a golden's expected/ (Plan 03 unit 3).
#
# Goldens layout (packages/ingestion/tests/goldens/<family>/<case>/):
#   input.md    the capture event fed to the filing engine
#   before/     the store copy the filing run starts from
#   expected/   the expected post-run store, for byte-diff grading
#
# Grading semantics are deliberately aligned with
# packages/core/scripts/eval-run-skill.sh's T3 built-in graders
# (RA_GRADER_DIFF / RA_GRADER_ASKED) so the same golden passes or fails
# consistently whether it's graded standalone via this script or wired into
# an eval case's graders/.
#
# Usage:
#   check-golden.sh <golden-dir> <worked-store-dir> [answer-file]
#   check-golden.sh --all <goldens-root> <worked-root>
#
# Single-case mode compares <worked-store-dir> against
# <golden-dir>/expected/ and prints "PASS <name>" or "FAIL <name>" plus a
# unified diff of every mismatched file (missing/unexpected files listed
# too). Timestamp-only frontmatter lines (captured_at:, filed_at:,
# generated_at:) are ignored, per Plan 03.
#
# If <golden-dir>/expected/question.md exists, the golden is an
# ask-a-question case: PASS requires the worked store to be byte-identical
# to <golden-dir>/before/ AND the recorded skill answer (path passed as the
# optional [answer-file] arg) to contain a question mark — mirroring
# packages/ingestion/evals/cases/06-ambiguous-question/graders/01-asked-not-written.sh.
#
# --all mode walks every case dir under <goldens-root> (any dir containing
# an expected/ subdir, recursively — the goldens tree nests <family>/<case>),
# looks up the matching <worked-root>/<same-relative-path>, and ends with a
# "SUMMARY: N passed, M failed" line. Exit 0 only when every case passes.
# An optional per-case answer file is picked up by convention at
# <worked-root>/<same-relative-path>.answer.txt if present.
#
# Silence is never valid: an empty/missing golden or worked dir is an
# explicit FAIL with a reason, never blank output.
#
# Refuses to run against any path resolving under data/ (same guard as
# packages/core/scripts/eval-run-skill.sh and eval-run.sh).
#
# Portable to bash 3.2: no associative arrays, no mapfile, no [[ ]].

set -u

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
  echo "Usage: ${SCRIPT_NAME} <golden-dir> <worked-store-dir> [answer-file]" >&2
  echo "       ${SCRIPT_NAME} --all <goldens-root> <worked-root>" >&2
  exit 1
}

refuse_if_under_data() {
  # $1 = label, $2 = path (need not exist)
  case "$2" in
    "$REPO_ROOT"/data/*|*/data/*)
      echo "FAIL refused: $1 resolves under data/: $2"
      exit 2
      ;;
  esac
}

abspath() {
  # $1 = path (may not exist) -> best-effort absolute path.
  if [ -d "$1" ]; then
    (cd "$1" && pwd)
  else
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *) printf '%s\n' "$(pwd)/$1" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Timestamp-normalized single-file diff
# ---------------------------------------------------------------------------

normalize_file() {
  # $1 = input file, $2 = output file — blanks out timestamp-only
  # frontmatter values so a timestamp difference alone never fails a golden.
  sed -E 's/^(captured_at|filed_at|generated_at):.*/\1: <ignored>/' "$1" > "$2"
}

# ---------------------------------------------------------------------------
# Recursive store diff: $1 = worked dir, $2 = golden dir (expected/ or
# before/). Prints missing/unexpected files and unified diffs of mismatches
# to stdout. Returns 0 if no differences remain after normalization.
# ---------------------------------------------------------------------------

diff_stores() {
  worked="$1"
  golden="$2"
  status=0

  worked_list_file="$(mktemp "${TMPDIR:-/tmp}/ra-golden-worked-list.XXXXXX")"
  golden_list_file="$(mktemp "${TMPDIR:-/tmp}/ra-golden-golden-list.XXXXXX")"
  (cd "$worked" && find . -type f | sed 's|^\./||' | sort) > "$worked_list_file"
  (cd "$golden" && find . -type f | sed 's|^\./||' | sort) > "$golden_list_file"

  missing="$(comm -23 "$golden_list_file" "$worked_list_file")"
  unexpected="$(comm -13 "$golden_list_file" "$worked_list_file")"
  common="$(comm -12 "$golden_list_file" "$worked_list_file")"
  rm -f "$worked_list_file" "$golden_list_file"

  if [ -n "$missing" ]; then
    status=1
    printf '%s\n' "$missing" | while IFS= read -r f; do
      [ -n "$f" ] && echo "MISSING: $f (expected but not written)"
    done
  fi

  if [ -n "$unexpected" ]; then
    status=1
    printf '%s\n' "$unexpected" | while IFS= read -r f; do
      [ -n "$f" ] && echo "UNEXPECTED: $f (written but not expected)"
    done
  fi

  if [ -n "$common" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      a="$(mktemp "${TMPDIR:-/tmp}/ra-golden-a.XXXXXX")"
      b="$(mktemp "${TMPDIR:-/tmp}/ra-golden-b.XXXXXX")"
      normalize_file "$golden/$f" "$a"
      normalize_file "$worked/$f" "$b"
      if ! diff -q "$a" "$b" >/dev/null 2>&1; then
        status=1
        echo "--- diff: $f (expected vs worked, timestamps ignored) ---"
        diff -u "$a" "$b" | sed "1s|^---.*|--- expected/$f|; 2s|^+++.*|+++ worked/$f|"
      fi
      rm -f "$a" "$b"
    done <<COMMON_EOF
$common
COMMON_EOF
  fi

  return "$status"
}

# ---------------------------------------------------------------------------
# check_one: grade one golden. $1 = golden-dir, $2 = worked-dir, $3 = name
# (for the PASS/FAIL line), $4 = optional answer-file.
# ---------------------------------------------------------------------------

check_one() {
  golden_dir="$1"
  worked_dir="$2"
  name="$3"
  answer_file="${4:-}"

  if [ ! -d "$golden_dir" ]; then
    echo "FAIL ${name}: golden dir not found: $golden_dir"
    return 1
  fi
  if [ ! -d "$golden_dir/expected" ]; then
    echo "FAIL ${name}: golden dir missing expected/: $golden_dir"
    return 1
  fi
  if [ ! -d "$worked_dir" ]; then
    echo "FAIL ${name}: worked store dir not found: $worked_dir"
    return 1
  fi

  if [ -f "$golden_dir/expected/question.md" ]; then
    before_dir="$golden_dir/before"
    if [ ! -d "$before_dir" ]; then
      echo "FAIL ${name}: question-case golden has no before/: $golden_dir"
      return 1
    fi

    diff_output="$(diff_stores "$worked_dir" "$before_dir")"
    diff_status=$?
    if [ "$diff_status" -ne 0 ]; then
      echo "FAIL ${name}: worked store diverged from before/ during an outstanding question"
      printf '%s\n' "$diff_output"
      return 1
    fi

    if [ -z "$answer_file" ]; then
      echo "FAIL ${name}: question-case has no recorded skill answer to check (pass answer-file arg)"
      return 1
    fi
    if [ ! -f "$answer_file" ]; then
      echo "FAIL ${name}: answer file not found: $answer_file"
      return 1
    fi
    if ! grep -q '?' "$answer_file"; then
      echo "FAIL ${name}: recorded skill answer does not look like a question (no '?' found)"
      return 1
    fi

    echo "PASS ${name}"
    return 0
  fi

  diff_output="$(diff_stores "$worked_dir" "$golden_dir/expected")"
  diff_status=$?
  if [ "$diff_status" -ne 0 ]; then
    echo "FAIL ${name}"
    printf '%s\n' "$diff_output"
    return 1
  fi

  echo "PASS ${name}"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--all" ]; then
  GOLDENS_ROOT_ARG="${2:-}"
  WORKED_ROOT_ARG="${3:-}"
  if [ -z "$GOLDENS_ROOT_ARG" ] || [ -z "$WORKED_ROOT_ARG" ]; then
    usage
  fi

  GOLDENS_ROOT_RAW="$(abspath "$GOLDENS_ROOT_ARG")"
  refuse_if_under_data "goldens-root" "$GOLDENS_ROOT_RAW"
  if [ ! -d "$GOLDENS_ROOT_RAW" ]; then
    echo "FAIL --all: goldens-root not found: $GOLDENS_ROOT_ARG"
    echo "SUMMARY: 0 passed, 1 failed"
    exit 1
  fi
  GOLDENS_ROOT="$GOLDENS_ROOT_RAW"

  WORKED_ROOT_RAW="$(abspath "$WORKED_ROOT_ARG")"
  refuse_if_under_data "worked-root" "$WORKED_ROOT_RAW"
  if [ ! -d "$WORKED_ROOT_RAW" ]; then
    echo "FAIL --all: worked-root not found: $WORKED_ROOT_ARG"
    echo "SUMMARY: 0 passed, 1 failed"
    exit 1
  fi
  WORKED_ROOT="$WORKED_ROOT_RAW"

  case_dirs="$(find "$GOLDENS_ROOT" -type d -name expected | sort)"
  if [ -z "$case_dirs" ]; then
    echo "FAIL --all: no golden cases found under $GOLDENS_ROOT (no expected/ dirs)"
    echo "SUMMARY: 0 passed, 0 failed"
    exit 1
  fi

  PASS_COUNT=0
  FAIL_COUNT=0

  while IFS= read -r expected_dir; do
    [ -n "$expected_dir" ] || continue
    golden_dir="$(dirname "$expected_dir")"
    case "$golden_dir" in
      "$GOLDENS_ROOT"/*) rel="${golden_dir#"$GOLDENS_ROOT"/}" ;;
      *) rel="$golden_dir" ;;
    esac
    worked_dir="$WORKED_ROOT/$rel"
    answer_file="$WORKED_ROOT/$rel.answer.txt"
    [ -f "$answer_file" ] || answer_file=""

    if check_one "$golden_dir" "$worked_dir" "$rel" "$answer_file"; then
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done <<CASE_DIRS_EOF
$case_dirs
CASE_DIRS_EOF

  echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  [ "$FAIL_COUNT" -eq 0 ]
  exit $?
fi

GOLDEN_DIR_ARG="${1:-}"
WORKED_DIR_ARG="${2:-}"
ANSWER_FILE_ARG="${3:-}"

if [ -z "$GOLDEN_DIR_ARG" ] || [ -z "$WORKED_DIR_ARG" ]; then
  usage
fi

GOLDEN_DIR_RAW="$(abspath "$GOLDEN_DIR_ARG")"
refuse_if_under_data "golden-dir" "$GOLDEN_DIR_RAW"
WORKED_DIR_RAW="$(abspath "$WORKED_DIR_ARG")"
refuse_if_under_data "worked-store-dir" "$WORKED_DIR_RAW"

if [ -n "$ANSWER_FILE_ARG" ]; then
  ANSWER_FILE_RAW="$(abspath "$ANSWER_FILE_ARG")"
  refuse_if_under_data "answer-file" "$ANSWER_FILE_RAW"
else
  ANSWER_FILE_RAW=""
fi

NAME="$(basename "$GOLDEN_DIR_RAW")"

if check_one "$GOLDEN_DIR_RAW" "$WORKED_DIR_RAW" "$NAME" "$ANSWER_FILE_RAW"; then
  exit 0
else
  exit 1
fi
