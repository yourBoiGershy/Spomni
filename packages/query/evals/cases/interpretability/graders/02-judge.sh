#!/bin/bash
# 02-judge.sh — wires judge.md into the grader chain per
# packages/core/contracts/eval-case.md's grader protocol: "judge.md is
# optional: a rubric run via eval-judge.sh <judge.md> <result-json>... A
# case that includes judge.md treats it as one more grader in the pass/fail
# chain." eval-run.sh only executes NN-<name>.{sh,py} files in graders/, so
# this numbered script is the wiring that invokes the shared judge runner.
#
# $1 = path to eval-run.sh's result JSON.
#
# Portable to bash 3.2 (macOS default) — no timeout(1).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"

RESULT_JSON="${1:-}"
JUDGE_MD="$SCRIPT_DIR/judge.md"
JUDGE_RUNNER="$REPO_ROOT/packages/core/scripts/eval-judge.sh"

if [ -z "$RESULT_JSON" ]; then
  echo "usage: 02-judge.sh <result.json>" >&2
  exit 1
fi

if [ ! -f "$JUDGE_MD" ]; then
  echo "02-judge.sh: missing rubric at $JUDGE_MD" >&2
  exit 1
fi

if [ ! -x "$JUDGE_RUNNER" ] && [ ! -f "$JUDGE_RUNNER" ]; then
  echo "02-judge.sh: missing judge runner at $JUDGE_RUNNER" >&2
  exit 1
fi

bash "$JUDGE_RUNNER" "$JUDGE_MD" "$RESULT_JSON"
exit $?
