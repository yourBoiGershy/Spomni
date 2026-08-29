#!/bin/bash
# eval-run.sh — T2 (tier: agent) eval-case runner per
# packages/core/contracts/eval-case.md.
#
# Usage: eval-run.sh <case-dir>
#
# Reads <case-dir>/prompt.md frontmatter, copies its fixture store into a
# hermetic temp workspace, spins up the query MCP server via a generated
# mcp-config, runs one headless `claude -p` agent turn against it, greps the
# result through the case's graders/, and prints one machine-parseable
# RESULT line. Every terminal path (success, grader failure, xfail flip,
# infra error) emits exactly one RESULT line — silence is never valid.
#
# Env overrides:
#   RA_EVAL_TIMEOUT_SECS  wall-clock guard in seconds (default 300)
#   RA_EVAL_KEEP=1        keep the temp workspace instead of deleting it
#   RA_EVAL_DRY_RUN=1     print the claude invocation instead of running it
#                         (used by the harness's own tests, not a case tier)
#                         and emit RESULT SKIP case=<name> reason=dry-run
#   RA_EVAL_FORCE=1       run a case even if it declares `runnable-when`
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no timeout(1) (backgrounded sleep-and-kill for the wall-clock guard).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CASE_DIR_ARG="${1:-}"
CASE_NAME="$(basename "${CASE_DIR_ARG:-unknown}")"

# result_line emits the one mandatory line and nothing else on this path.
result_error() {
  # $1 = reason
  echo "RESULT ERROR case=${CASE_NAME} reason=\"$1\""
  exit 2
}

if [ -z "$CASE_DIR_ARG" ]; then
  result_error "usage: eval-run.sh <case-dir>"
fi

if [ ! -d "$CASE_DIR_ARG" ]; then
  result_error "case directory not found: ${CASE_DIR_ARG}"
fi

CASE_DIR="$(cd "$CASE_DIR_ARG" && pwd)"
CASE_NAME="$(basename "$CASE_DIR")"
PROMPT_FILE="$CASE_DIR/prompt.md"

if [ ! -f "$PROMPT_FILE" ]; then
  result_error "missing prompt.md in ${CASE_DIR}"
fi

# Extract the YAML frontmatter block (between the first two '---' lines).
extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

# Extract a single scalar field value from the frontmatter, e.g. "tier".
extract_field() {
  fm="$1"
  key="$2"
  printf '%s\n' "$fm" | sed -n "s/^${key}: *//p" | head -1
}

# Extract a YAML list field's items, e.g. "allowed-tools:\n  - a\n  - b".
extract_list() {
  fm="$1"
  key="$2"
  printf '%s\n' "$fm" | awk -v key="${key}:" '
    $0 == key { flag=1; next }
    flag && /^[^[:space:]]/ { flag=0 }
    flag && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      print line
    }
  '
}

FRONTMATTER="$(extract_frontmatter "$PROMPT_FILE")"
BODY="$(awk '/^---$/ { c++; next } c >= 2 { print }' "$PROMPT_FILE")"

TIER="$(extract_field "$FRONTMATTER" tier)"
STORE="$(extract_field "$FRONTMATTER" store)"
MAX_TURNS="$(extract_field "$FRONTMATTER" max-turns)"
MODEL="$(extract_field "$FRONTMATTER" model)"
XFAIL="$(extract_field "$FRONTMATTER" xfail)"
RUNNABLE_WHEN="$(extract_field "$FRONTMATTER" runnable-when)"
ALLOWED_TOOLS_LIST="$(extract_list "$FRONTMATTER" allowed-tools)"

MAX_TURNS="${MAX_TURNS:-8}"
MODEL="${MODEL:-haiku}"

if [ -z "$TIER" ]; then
  result_error "prompt.md frontmatter missing required field: tier"
fi

if [ "$TIER" != "agent" ]; then
  result_error "eval-run.sh only handles tier: agent (case has tier: ${TIER}) — use eval-run-skill.sh"
fi

if [ -z "$STORE" ]; then
  result_error "prompt.md frontmatter missing required field: store"
fi

if [ -z "$ALLOWED_TOOLS_LIST" ]; then
  result_error "prompt.md frontmatter missing required field: allowed-tools (tier: agent requires it)"
fi

if [ -z "$BODY" ]; then
  result_error "prompt.md has no body (task prompt) after frontmatter"
fi

# --- runnable-when: SKIP unless forced (the plan the case exercises isn't built) ---
if [ -n "$RUNNABLE_WHEN" ] && [ "${RA_EVAL_FORCE:-}" != "1" ]; then
  echo "RESULT SKIP case=${CASE_NAME} reason=runnable-when:${RUNNABLE_WHEN}"
  exit 0
fi

# --- PII rule: store must never resolve under data/ (packages/core/contracts/eval-case.md) ---
STORE_ABS_RAW="${REPO_ROOT}/${STORE}"
STORE_REAL="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$STORE_ABS_RAW" 2>/dev/null)"
DATA_REAL="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "${REPO_ROOT}/data")"

case "$STORE_REAL" in
  "$DATA_REAL"|"$DATA_REAL"/*)
    result_error "store path resolves under data/ (${STORE}) — evals must run only against fixtures, never real user data"
    ;;
esac

if [ ! -d "$STORE_REAL" ]; then
  result_error "store directory not found: ${STORE} (resolved to ${STORE_REAL})"
fi

# --- pre-check: query MCP server dependencies installed ---
if [ ! -d "${REPO_ROOT}/packages/query/server/node_modules" ]; then
  result_error "packages/query/server/node_modules missing — run npm install in packages/query/server"
fi

# --- hermetic temp workspace ---
TMP_DIR="$(mktemp -d)"
STORE_COPY="${TMP_DIR}/store"
CACHE_DIR="${TMP_DIR}/cache"
CONFIG_PATH="${TMP_DIR}/mcp-config.json"
RESULT_JSON="${TMP_DIR}/result.json"

cleanup() {
  if [ "${RA_EVAL_KEEP:-0}" = "1" ]; then
    echo "eval-run.sh: RA_EVAL_KEEP=1 — keeping temp workspace at ${TMP_DIR}" >&2
  else
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

cp -R "$STORE_REAL" "$STORE_COPY"
mkdir -p "$CACHE_DIR"

python3 - "$REPO_ROOT" "$STORE_COPY" "$CACHE_DIR" "$CONFIG_PATH" <<'PYEOF'
import json
import sys

repo_root, store_copy, cache_dir, config_path = sys.argv[1:5]

config = {
    "mcpServers": {
        "ra-query": {
            "command": "node",
            "args": [
                "--experimental-strip-types",
                repo_root + "/packages/query/server/src/index.ts",
                "--store",
                store_copy,
            ],
            "env": {
                "RA_CACHE_DIR": cache_dir,
                "RA_CORE_SCRIPTS_DIR": repo_root + "/packages/core/scripts",
            },
        }
    }
}

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
PYEOF

if [ ! -f "$CONFIG_PATH" ]; then
  result_error "failed to write mcp-config.json"
fi

# comma-join allowed-tools
ALLOWED_TOOLS="$(printf '%s\n' "$ALLOWED_TOOLS_LIST" | paste -sd, -)"

TIMEOUT_SECS="${RA_EVAL_TIMEOUT_SECS:-300}"

CLAUDE_CMD="claude -p <prompt body, ${#BODY} chars> --strict-mcp-config --mcp-config ${CONFIG_PATH} --allowedTools \"${ALLOWED_TOOLS}\" --max-turns ${MAX_TURNS} --model ${MODEL} --output-format json"

if [ "${RA_EVAL_DRY_RUN:-0}" = "1" ]; then
  echo "DRY RUN: ${CLAUDE_CMD}"
  echo "DRY RUN: cwd=${TMP_DIR}"
  echo "DRY RUN: mcp-config=${CONFIG_PATH}"
  echo "RESULT SKIP case=${CASE_NAME} reason=dry-run"
  exit 0
fi

(
  cd "$TMP_DIR" || exit 1
  claude -p "$BODY" \
    --strict-mcp-config \
    --mcp-config "$CONFIG_PATH" \
    --allowedTools "$ALLOWED_TOOLS" \
    --max-turns "$MAX_TURNS" \
    --model "$MODEL" \
    --output-format json
) > "$RESULT_JSON" 2>"${TMP_DIR}/stderr.log" &
CLAUDE_PID=$!

( sleep "$TIMEOUT_SECS"; kill -9 "$CLAUDE_PID" 2>/dev/null ) &
GUARD_PID=$!

wait "$CLAUDE_PID" 2>/dev/null
kill "$GUARD_PID" 2>/dev/null
wait "$GUARD_PID" 2>/dev/null

if [ ! -s "$RESULT_JSON" ]; then
  echo "eval-run.sh: result.json is empty (result left at ${RESULT_JSON} unless removed by cleanup) — likely a timeout after ${TIMEOUT_SECS}s" >&2
  result_error "no result JSON produced (possible timeout after ${TIMEOUT_SECS}s) — see ${TMP_DIR}/stderr.log"
fi

EXTRACT="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as exc:
    print('ERROR')
    print(exc)
    sys.exit(0)
print(data.get('is_error'))
print(data.get('num_turns'))
print(data.get('total_cost_usd'))
" "$RESULT_JSON")"

FIRST_LINE="$(printf '%s\n' "$EXTRACT" | sed -n '1p')"
if [ "$FIRST_LINE" = "ERROR" ]; then
  PARSE_ERR="$(printf '%s\n' "$EXTRACT" | sed -n '2p')"
  result_error "result JSON at ${RESULT_JSON} failed to parse: ${PARSE_ERR}"
fi

IS_ERROR="$FIRST_LINE"
NUM_TURNS="$(printf '%s\n' "$EXTRACT" | sed -n '2p')"
COST_USD="$(printf '%s\n' "$EXTRACT" | sed -n '3p')"

echo "eval-run.sh: result at ${RESULT_JSON} (is_error=${IS_ERROR})" >&2

# --- graders/NN-<name>.{sh,py}, in lexical order, exit code only ---
GRADERS_DIR="$CASE_DIR/graders"
OUTCOME_BASE="PASS"

if [ -d "$GRADERS_DIR" ]; then
  for g in $(ls "$GRADERS_DIR" 2>/dev/null | grep -E '^[0-9]+-.*\.(sh|py)$' | sort); do
    GPATH="$GRADERS_DIR/$g"
    case "$g" in
      *.py) python3 "$GPATH" "$RESULT_JSON"; GSTATUS=$? ;;
      *)
        if [ -x "$GPATH" ]; then
          "$GPATH" "$RESULT_JSON"
        else
          bash "$GPATH" "$RESULT_JSON"
        fi
        GSTATUS=$?
        ;;
    esac
    if [ "$GSTATUS" -ne 0 ]; then
      OUTCOME_BASE="FAIL"
    fi
  done
fi

if [ -n "$XFAIL" ]; then
  if [ "$OUTCOME_BASE" = "FAIL" ]; then
    OUTCOME="XFAIL"
    FINAL_EXIT=0
  else
    OUTCOME="XPASS"
    FINAL_EXIT=1
  fi
else
  OUTCOME="$OUTCOME_BASE"
  if [ "$OUTCOME_BASE" = "PASS" ]; then
    FINAL_EXIT=0
  else
    FINAL_EXIT=1
  fi
fi

if [ "$OUTCOME" = "XFAIL" ] || [ "$OUTCOME" = "XPASS" ]; then
  echo "RESULT ${OUTCOME} case=${CASE_NAME} cost_usd=${COST_USD} turns=${NUM_TURNS} xfail_reason=\"${XFAIL}\""
else
  echo "RESULT ${OUTCOME} case=${CASE_NAME} cost_usd=${COST_USD} turns=${NUM_TURNS}"
fi

exit "$FINAL_EXIT"
