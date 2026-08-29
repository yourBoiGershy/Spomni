#!/usr/bin/env bash
# eval-judge.sh — structured-output LLM judge for eval-case graders.
#
# Usage: eval-judge.sh <judge.md rubric path> <result.json path>
#
# Extracts the evaluated agent's answer text (the `result` field) from
# result.json, builds a judge prompt from the rubric body + the answer, and
# runs one cheap haiku `claude -p` call constrained to a pass/fail JSON
# schema (per packages/core/contracts/eval-case.md's grader protocol).
#
# The judge grades ONLY what's in judge.md — this script never injects its
# own criteria.
#
# Env:
#   RA_EVAL_JUDGE_MODEL   model override (default: haiku)
#   RA_EVAL_TIMEOUT_SECS  wall-clock guard in seconds (default: 120)
#   RA_EVAL_DRY_RUN=1     print the claude command instead of running it
#   RA_EVAL_PARSE_TEST=<file>  test-only: skip the claude call, parse <file>
#                              as if it were the claude-result JSON, and
#                              exit via the normal verdict path (no rubric/
#                              result.json args required in this mode).
#
# Exit codes:
#   0  verdict: pass
#   1  verdict: fail (reason printed to stderr)
#   2  judge error (malformed/missing output, or usage error) — never silent
#
# Portable to bash 3.2. No timeout(1) — uses a backgrounded sleep-and-kill.

set -u

JUDGE_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["pass","fail"]},"reason":{"type":"string"}},"required":["verdict","reason"]}'

# -----------------------------------------------------------------------
# Parses a claude-result JSON file (as produced by `claude -p
# --output-format json`) and prints the verdict outcome, exiting per the
# documented exit-code contract. Factored out so RA_EVAL_PARSE_TEST can
# exercise it without a live claude call.
# -----------------------------------------------------------------------
parse_judge_result() {
    local claude_result_file="$1"

    if [ ! -f "$claude_result_file" ]; then
        echo "JUDGE ERROR: claude result file not found: $claude_result_file" >&2
        return 2
    fi

    local parsed
    parsed=$(python3 -c '
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print("PARSE_ERROR malformed JSON: %s" % e)
    sys.exit(0)

structured = data.get("structured_output")
if not isinstance(structured, dict):
    print("PARSE_ERROR missing structured_output field")
    sys.exit(0)

verdict = structured.get("verdict")
reason = structured.get("reason", "")
if verdict not in ("pass", "fail"):
    print("PARSE_ERROR missing/invalid verdict field: %r" % (verdict,))
    sys.exit(0)

cost = data.get("total_cost_usd", "")
# Fields are newline-separated; reason may contain no newlines by schema
# but we defensively collapse any that appear.
reason_flat = " ".join(str(reason).splitlines())
print("OK")
print(verdict)
print(cost)
print(reason_flat)
' "$claude_result_file")

    local status_line
    status_line=$(printf '%s\n' "$parsed" | sed -n '1p')

    case "$status_line" in
        PARSE_ERROR*)
            echo "JUDGE ERROR: ${status_line#PARSE_ERROR }" >&2
            return 2
            ;;
        OK) ;;
        *)
            echo "JUDGE ERROR: unrecognized parse status: $status_line" >&2
            return 2
            ;;
    esac

    local verdict cost reason
    verdict=$(printf '%s\n' "$parsed" | sed -n '2p')
    cost=$(printf '%s\n' "$parsed" | sed -n '3p')
    reason=$(printf '%s\n' "$parsed" | sed -n '4p')

    if [ "$verdict" = "pass" ]; then
        printf 'JUDGE pass cost_usd=%s reason=%s\n' "$cost" "$reason"
        return 0
    else
        printf 'JUDGE fail cost_usd=%s reason=%s\n' "$cost" "$reason" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------
# Test hook: RA_EVAL_PARSE_TEST=<file> exercises parse_judge_result() alone,
# without a live claude call or rubric/result.json arguments.
# -----------------------------------------------------------------------
if [ -n "${RA_EVAL_PARSE_TEST:-}" ]; then
    parse_judge_result "$RA_EVAL_PARSE_TEST"
    exit $?
fi

# -----------------------------------------------------------------------
# Normal path
# -----------------------------------------------------------------------

judge_md="${1:-}"
result_json="${2:-}"

if [ -z "$judge_md" ] || [ -z "$result_json" ]; then
    echo "JUDGE ERROR: usage: eval-judge.sh <judge.md rubric path> <result.json path>" >&2
    exit 2
fi

if [ ! -f "$judge_md" ]; then
    echo "JUDGE ERROR: rubric file not found: $judge_md" >&2
    exit 2
fi

if [ ! -f "$result_json" ]; then
    echo "JUDGE ERROR: result.json not found: $result_json" >&2
    exit 2
fi

model="${RA_EVAL_JUDGE_MODEL:-haiku}"
timeout_secs="${RA_EVAL_TIMEOUT_SECS:-120}"

# Extract the evaluated agent's answer text (`result` field) from result.json.
answer_text=$(python3 -c '
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write("malformed result.json: %s\n" % e)
    sys.exit(1)

result = data.get("result")
if result is None:
    sys.stderr.write("result.json missing '\''result'\'' field\n")
    sys.exit(1)

sys.stdout.write(str(result))
' "$result_json")
extract_status=$?

if [ "$extract_status" -ne 0 ]; then
    echo "JUDGE ERROR: failed to extract 'result' field from $result_json" >&2
    exit 2
fi

rubric_body=$(cat "$judge_md")

prompt_file=$(mktemp)
trap 'rm -f "$prompt_file"' EXIT

{
    printf '%s\n' "$rubric_body"
    printf '\n--- OUTPUT UNDER EVALUATION ---\n'
    printf '%s\n' "$answer_text"
} > "$prompt_file"

judge_prompt=$(cat "$prompt_file")

if [ -n "${RA_EVAL_DRY_RUN:-}" ]; then
    printf 'claude -p <judge-prompt> --output-format json --json-schema %s --model %s --max-turns 3\n' "$JUDGE_SCHEMA" "$model"
    exit 0
fi

work_dir=$(mktemp -d)
result_file=$(mktemp)
trap 'rm -f "$prompt_file" "$result_file"; rm -rf "$work_dir"' EXIT

(
    cd "$work_dir" || exit 2
    claude -p "$judge_prompt" \
        --output-format json \
        --json-schema "$JUDGE_SCHEMA" \
        --model "$model" \
        --max-turns 3 \
        > "$result_file" 2>&1
) &
claude_pid=$!

(
    sleep "$timeout_secs"
    kill -0 "$claude_pid" 2>/dev/null && kill -9 "$claude_pid" 2>/dev/null
) >/dev/null 2>&1 &
watchdog_pid=$!

wait "$claude_pid"
claude_status=$?

pkill -P "$watchdog_pid" 2>/dev/null || true
kill -0 "$watchdog_pid" 2>/dev/null && kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

if [ "$claude_status" -ne 0 ]; then
    echo "JUDGE ERROR: claude -p exited non-zero ($claude_status) or timed out after ${timeout_secs}s" >&2
    exit 2
fi

parse_judge_result "$result_file"
exit $?
