#!/usr/bin/env bash
# eval-run-skill.sh — T3 (skill-tier) eval case runner
# (packages/core/contracts/eval-case.md).
#
# Usage: eval-run-skill.sh <case-dir>
#
# A T3 case grades a *skill* run: the case's `store` (usually its own
# before/ dir, or another case's before/ it references) is copied into a
# fresh temp cwd — excluding any `expected/` or `graders/` subdirectory the
# fixture happens to colocate with the store, so the golden answer never
# leaks into the workspace the agent is evaluated in — a headless `claude
# -p` invocation works on that copy with
# NO mcp-config at all (T3 needs no MCP server — the store is plain files in
# cwd), and the case's graders/ then judge the worked copy. Two built-in
# graders are exported for cases to call: RA_GRADER_DIFF (recursive byte
# diff of the worked store vs expected/) and RA_GRADER_ASKED (the skill
# asked a clarifying question instead of writing anything).
#
# The invocation runs with `--permission-mode bypassPermissions`: the temp
# cwd is a hermetic throwaway copy of the fixture (never the real store, per
# the PII refusal below), so there is nothing to protect the skill from
# writing to — without this, headless `-p` runs deny every Write/Bash tool
# call by default (no TTY to approve them), so a skill that must actually
# create files (e.g. a proposal wake-up) silently produces nothing and the
# transcript just says it's "awaiting permission". Skills that correctly
# produce zero writes (e.g. a declined-proposal case) are unaffected either
# way.
#
# Env knobs:
#   RA_EVAL_FORCE=1        run a case even if it declares `runnable-when`.
#   RA_EVAL_TIMEOUT_SECS   wall-clock guard for the claude invocation
#                          (default 300; macOS has no timeout(1), so this is
#                          a backgrounded sleep-and-kill).
#   RA_EVAL_DRY_RUN=1      print the claude command instead of running it.
#
# Emits exactly one `RESULT ...` line per run (silence is never valid):
#   RESULT PASS  case=<name> cost_usd=<x> turns=<n>
#   RESULT FAIL  case=<name> cost_usd=<x> turns=<n>
#   RESULT XFAIL case=<name> cost_usd=<x> turns=<n>
#   RESULT XPASS case=<name> cost_usd=<x> turns=<n>
#   RESULT SKIP  case=<name> reason=<reason>
#   RESULT ERROR case=<name> reason=<reason>
#
# Exit codes: 0 = PASS/XFAIL/SKIP; 1 = FAIL/XPASS/ERROR;
# 2 = refused (store/expected resolves under data/).
#
# Portable to bash 3.2: no associative arrays, no mapfile, no [[ ]].

set -u

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
  echo "Usage: ${SCRIPT_NAME} <case-dir>" >&2
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi

CASE_DIR_ARG="$1"
if [ ! -d "$CASE_DIR_ARG" ]; then
  CASE_NAME="$(basename "$CASE_DIR_ARG")"
  echo "RESULT ERROR case=${CASE_NAME} reason=case-dir-not-found:${CASE_DIR_ARG}"
  exit 1
fi
CASE_DIR="$(cd "$CASE_DIR_ARG" && pwd)"
CASE_NAME="$(basename "$CASE_DIR")"

PROMPT_FILE="$CASE_DIR/prompt.md"
if [ ! -f "$PROMPT_FILE" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=missing-prompt.md"
  exit 1
fi

# ---------------------------------------------------------------------------
# Frontmatter parsing
# ---------------------------------------------------------------------------

# Line number of the closing `---` (frontmatter opens on line 1).
FM_END="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$PROMPT_FILE")"
if [ -z "$FM_END" ] || [ "$(sed -n '1p' "$PROMPT_FILE")" != "---" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=malformed-frontmatter"
  exit 1
fi

fm_field() {
  # $1 = frontmatter key -> prints its value (first match), trimmed.
  awk -v end="$FM_END" -v key="^$1:" \
    'NR>1 && NR<end && $0 ~ key { sub(key, "", $0); sub(/^[ \t]+/, "", $0); print; exit }' \
    "$PROMPT_FILE"
}

TIER="$(fm_field tier)"
STORE_REL="$(fm_field store)"
EXPECTED_REL="$(fm_field expected)"
MAX_TURNS="$(fm_field max-turns)"
MODEL="$(fm_field model)"
XFAIL="$(fm_field xfail)"
RUNNABLE_WHEN="$(fm_field runnable-when)"

MAX_TURNS="${MAX_TURNS:-8}"
MODEL="${MODEL:-haiku}"

PROMPT_BODY="$(awk -v end="$FM_END" 'NR>end' "$PROMPT_FILE")"

if [ "$TIER" != "skill" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=tier-not-skill:${TIER}"
  exit 1
fi

if [ -z "$STORE_REL" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=missing-store-field"
  exit 1
fi

if [ -z "$EXPECTED_REL" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=missing-expected-field"
  exit 1
fi

# ---------------------------------------------------------------------------
# Path resolution + PII refusal (never a store/expected under data/)
# ---------------------------------------------------------------------------

resolve_path() {
  # $1 = repo-relative (or absolute) path -> absolute path (may not exist).
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
  esac
}

STORE_PATH="$(resolve_path "$STORE_REL")"
EXPECTED_PATH="$(resolve_path "$EXPECTED_REL")"

refuse_if_under_data() {
  # $1 = label, $2 = resolved path
  case "$2" in
    "$REPO_ROOT"/data/*|*/data/*)
      echo "RESULT ERROR case=${CASE_NAME} reason=refused-data-path:$1=$2"
      exit 2
      ;;
  esac
}

refuse_if_under_data "store" "$STORE_PATH"
refuse_if_under_data "expected" "$EXPECTED_PATH"

# ---------------------------------------------------------------------------
# runnable-when: SKIP unless forced (the plan the case exercises isn't built)
# ---------------------------------------------------------------------------

if [ -n "$RUNNABLE_WHEN" ] && [ "${RA_EVAL_FORCE:-}" != "1" ]; then
  echo "RESULT SKIP case=${CASE_NAME} reason=runnable-when:${RUNNABLE_WHEN}"
  exit 0
fi

if [ ! -d "$STORE_PATH" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=store-not-found:${STORE_PATH}"
  exit 1
fi

if [ ! -d "$EXPECTED_PATH" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=expected-not-found:${EXPECTED_PATH}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Temp workspace: copy store -> <temp>/store, no MCP config, plain cwd.
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ra-eval-skill.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Copy the store fixture into the workspace, but never the golden
# `expected/` (or a sibling `graders/`) if either happens to live inside
# the fixture dir itself — some fixtures colocate their golden artifacts
# next to the input store (e.g. scheduling-intent/clear-intent/expected/),
# and copying that in would hand the evaluated agent the answer key.
mkdir -p "$TMP_DIR/store"
(
  cd "$STORE_PATH" && find . -mindepth 1 -maxdepth 1 \
    ! -name expected ! -name graders \
    -exec cp -R {} "$TMP_DIR/store/" \;
)

RESULT_JSON="$TMP_DIR/result.json"

# ---------------------------------------------------------------------------
# Built-in graders: written into the temp workspace, exported by path so a
# case's own graders/*.sh|py can invoke them.  Contract: grader $1 = worked
# store dir, $2 = result.json path.
# ---------------------------------------------------------------------------

RA_GRADER_DIFF="$TMP_DIR/ra-grader-diff.sh"
cat > "$RA_GRADER_DIFF" <<'EOF'
#!/usr/bin/env bash
# Built-in grader: recursive byte-diff of the worked store vs expected/.
# Usage: ra-grader-diff.sh <worked-store-dir> [expected-dir]
# Empty diff = pass (exit 0); any difference = fail (exit non-zero).
set -u
worked="${1:-}"
expected="${2:-${RA_EVAL_EXPECTED_DIR:-}}"
if [ -z "$worked" ] || [ -z "$expected" ]; then
  echo "ra-grader-diff.sh: need <worked-store-dir> and expected dir (arg or RA_EVAL_EXPECTED_DIR)" >&2
  exit 1
fi
diff -r "$worked" "$expected"
EOF
chmod +x "$RA_GRADER_DIFF"

RA_GRADER_ASKED="$TMP_DIR/ra-grader-asked.py"
cat > "$RA_GRADER_ASKED" <<'EOF'
#!/usr/bin/env python3
# Built-in grader: the skill asked a clarifying question instead of writing
# anything -- result JSON's `result` text contains a question mark AND the
# worked store is byte-identical to the pre-run (before/) store.
# Usage: ra-grader-asked.py <worked-store-dir> <result-json> [before-dir]
import json
import os
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("ra-grader-asked.py: need <worked-store-dir> <result-json> [before-dir]\n")
        return 1
    worked = sys.argv[1]
    result_json = sys.argv[2]
    before = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if not before:
        sys.stderr.write("ra-grader-asked.py: no before dir (arg 3 or RA_EVAL_BEFORE_DIR)\n")
        return 1
    with open(result_json) as f:
        data = json.load(f)
    text = data.get("result", "") or ""
    if "?" not in text:
        sys.stderr.write("ra-grader-asked.py: result text has no question mark\n")
        return 1
    diff = subprocess.run(["diff", "-r", worked, before], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if diff.returncode != 0:
        sys.stderr.write("ra-grader-asked.py: store was modified\n")
        sys.stderr.write(diff.stdout.decode("utf-8", "replace"))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF
chmod +x "$RA_GRADER_ASKED"

export RA_GRADER_DIFF
export RA_GRADER_ASKED
export RA_EVAL_EXPECTED_DIR="$EXPECTED_PATH"
export RA_EVAL_BEFORE_DIR="$STORE_PATH"

# ---------------------------------------------------------------------------
# Run the skill (or print the command, in dry-run mode).
# ---------------------------------------------------------------------------

if [ "${RA_EVAL_DRY_RUN:-0}" = "1" ]; then
  echo "DRY RUN (cwd=${TMP_DIR}):"
  echo "claude -p <prompt body, $(printf '%s' "$PROMPT_BODY" | wc -c | tr -d ' ') bytes> --strict-mcp-config --permission-mode bypassPermissions --max-turns ${MAX_TURNS} --model ${MODEL} --output-format json > ${RESULT_JSON}"
  echo "RESULT SKIP case=${CASE_NAME} reason=dry-run"
  exit 0
fi

TIMEOUT_SECS="${RA_EVAL_TIMEOUT_SECS:-300}"

(
  cd "$TMP_DIR" && claude -p "$PROMPT_BODY" --strict-mcp-config --permission-mode bypassPermissions --max-turns "$MAX_TURNS" --model "$MODEL" --output-format json > "$RESULT_JSON" 2> "$TMP_DIR/stderr.log"
) &
CLAUDE_PID=$!

(
  sleep "$TIMEOUT_SECS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill -9 "$CLAUDE_PID" 2>/dev/null
  fi
) >/dev/null 2>&1 &
WATCHDOG_PID=$!

wait "$CLAUDE_PID"
CLAUDE_EXIT=$?
pkill -P "$WATCHDOG_PID" 2>/dev/null || true
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [ ! -s "$RESULT_JSON" ]; then
  echo "RESULT ERROR case=${CASE_NAME} reason=no-result-json:exit=${CLAUDE_EXIT}"
  exit 1
fi

COST_USD="$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('total_cost_usd', 0))
except Exception:
    print(0)" "$RESULT_JSON" 2>/dev/null)"
[ -n "$COST_USD" ] || COST_USD=0

NUM_TURNS="$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('num_turns', 0))
except Exception:
    print(0)" "$RESULT_JSON" 2>/dev/null)"
[ -n "$NUM_TURNS" ] || NUM_TURNS=0

# ---------------------------------------------------------------------------
# Graders: run in lexical order against the worked store copy.
# ---------------------------------------------------------------------------

GRADERS_DIR="$CASE_DIR/graders"
GRADER_FAIL=0

if [ -d "$GRADERS_DIR" ]; then
  for g in "$GRADERS_DIR"/*; do
    [ -f "$g" ] || continue
    base="$(basename "$g")"
    case "$base" in
      judge.md) continue ;;
    esac
    case "$g" in
      *.py)
        python3 "$g" "$TMP_DIR/store" "$RESULT_JSON"
        rc=$?
        ;;
      *)
        [ -x "$g" ] || chmod +x "$g" 2>/dev/null
        "$g" "$TMP_DIR/store" "$RESULT_JSON"
        rc=$?
        ;;
    esac
    if [ "$rc" -ne 0 ]; then
      GRADER_FAIL=1
      echo "grader failed: ${base}" >&2
    fi
  done
fi

# ---------------------------------------------------------------------------
# xfail inversion + result line
# ---------------------------------------------------------------------------

if [ "$GRADER_FAIL" -eq 0 ]; then
  if [ -n "$XFAIL" ]; then
    OUTCOME="XPASS"
  else
    OUTCOME="PASS"
  fi
else
  if [ -n "$XFAIL" ]; then
    OUTCOME="XFAIL"
  else
    OUTCOME="FAIL"
  fi
fi

echo "RESULT ${OUTCOME} case=${CASE_NAME} cost_usd=${COST_USD} turns=${NUM_TURNS}"

case "$OUTCOME" in
  PASS|XFAIL) exit 0 ;;
  *) exit 1 ;;
esac
