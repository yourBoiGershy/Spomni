#!/usr/bin/env bash
# summarize-thread.sh — one headless model call per chat thread, strict
# JSON out (packages/ingestion/specs/thread-summary.md 1.0.0, plan 32 D1).
#
# Usage:
#   summarize-thread.sh <event-file> [--model <m>] [--out <path>]
#
# <event-file> is a chat-message capture event (capture-event 1.2.0):
# YAML frontmatter followed by a single-line JSON body ({"chatID",
# "accountID","network","title","chatType","messages":[...]}). This script
# reads the whole thread once, prompts a headless `claude -p` call for a
# structured summary (people, gist, open threads, commitments, provenance-
# tagged facts), validates the result against thread-summary.md's schema,
# and prints it (or writes it to --out).
#
# Env:
#   RA_THREAD_MODEL          model override (default: sonnet -- faster and
#                            more schema-reliable than haiku on this call;
#                            haiku still selectable via RA_THREAD_MODEL=haiku)
#   RA_THREAD_TIMEOUT_SECS   wall-clock guard in seconds (default: 180)
#   RA_THREAD_DRY_RUN=1      print the prompt + claude command, exit 0
#   RA_THREAD_PARSE_TEST=<file>  test-only: skip the claude call, parse
#                                <file> as the claude-result JSON, validate
#                                and print via the normal path
#
# Exit codes:
#   0  summary printed (or written to --out), schema-valid
#   2  usage error
#   3  claude -p exited non-zero or timed out
#   4  model output failed schema validation (reason on stderr)
#
# Portable to bash 3.2. No timeout(1) — backgrounded sleep-and-kill
# watchdog, mirrors packages/core/scripts/eval-judge.sh.

set -u

# -----------------------------------------------------------------------
# Builds the compacted thread + prompt from an event file. Prints the
# prompt to stdout; prints the parsed capture_id/chat_id/chat_type to fd 3
# (tab-separated) for the caller to reuse without re-parsing the file.
# -----------------------------------------------------------------------
build_prompt() {
    local event_file="$1"

    python3 -c '
import json
import re
import sys

path = sys.argv[1]

with open(path) as f:
    raw = f.read()

# Split frontmatter (--- ... ---) from the single-line JSON body.
m = re.match(r"^---\n(.*?)\n---\n(.*)$", raw, re.DOTALL)
if not m:
    sys.stderr.write("summarize-thread.sh: event file missing frontmatter block\n")
    sys.exit(2)

frontmatter_text, body_text = m.group(1), m.group(2).strip()

capture_id = None
for line in frontmatter_text.splitlines():
    line = line.strip()
    if line.startswith("id:"):
        capture_id = line.split(":", 1)[1].strip().strip(chr(34))
        break

if not capture_id:
    sys.stderr.write("summarize-thread.sh: event file frontmatter missing id field\n")
    sys.exit(2)

try:
    body = json.loads(body_text.splitlines()[0]) if body_text else {}
except Exception as e:
    sys.stderr.write("summarize-thread.sh: event body is not valid JSON: %s\n" % e)
    sys.exit(2)

chat_id = body.get("chatID", "")
chat_type = body.get("chatType", "single")
title = body.get("title", "")
messages = body.get("messages", []) or []

def truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")

lines = []
for msg in messages:
    if not isinstance(msg, dict):
        continue
    if str(msg.get("type", "")).upper() == "NOTICE":
        continue
    if truthy(msg.get("isDeleted", False)):
        continue
    text = msg.get("text")
    if not text or not str(text).strip():
        continue
    sender = msg.get("senderName") or msg.get("senderID") or "unknown"
    ts = msg.get("timestamp", "")
    who = "self" if truthy(msg.get("isSender", False)) else "other"
    lines.append("[%s] %s (%s): %s" % (ts, sender, who, text))

schema = """{
  "schema_version": "1.0.0",
  "capture_id": "<id from frontmatter>",
  "chat_id": "<chatID>",
  "chat_type": "single|group",
  "skip": null | {"reason": "bot|broadcast|self-note|security-notice|empty"},
  "people": [{"display_name": str, "sender_ids": [str], "is_self": bool,
              "role_guess": "friend|family|colleague|client|collaborator|acquaintance|unsolicited|unknown",
              "message_count": int (optional, >= 0)}],
  "relationship_kind_guess": "friend|family|colleague|client|collaborator|acquaintance|unsolicited|unknown|group",
  "gist": str,
  "open_threads": [str],
  "commitments": [{"owner": "user|<display_name>", "what": str, "by": str|null}],
  "facts": [{"about": "<display_name>|user", "text": str, "provenance": "told-by-user|inferred-from-thread"}]
}"""

if not lines:
    prompt = (
        "This chat thread has no content messages after dropping system "
        "rows, deleted messages, and empty-text rows. Respond with ONLY "
        "this JSON object (no prose, no markdown fence), filling capture_id "
        "and chat_id/chat_type exactly as given:\n\n"
        "{\"schema_version\": \"1.0.0\", \"capture_id\": \"%s\", \"chat_id\": \"%s\", "
        "\"chat_type\": \"%s\", \"skip\": {\"reason\": \"empty\"}, \"people\": [], "
        "\"relationship_kind_guess\": \"unknown\", \"gist\": \"\", "
        "\"open_threads\": [], \"commitments\": [], \"facts\": []}"
        % (capture_id, chat_id, chat_type)
    )
else:
    thread_text = "\n".join(lines)
    prompt = """You are analyzing one chat thread to produce a structured, \
provenance-tagged summary. The message marked "(self)" is written by "the \
user"; every "(other)" message is from someone else in the thread.

Chat title: %s
Chat type: %s

Thread (chronological):
%s

Rules:
- Never invent facts. Use provenance "told-by-user" ONLY for things the \
user literally wrote about themselves or the other person. Everything else \
you conclude from tone/context/behavior is "inferred-from-thread".
- "skip" is ONLY for threads with no person on the other end: a bot, a \
broadcast/announcement channel, a self-chat ("Note to self"), or a \
security/OTP notice channel. A cold pitch from a real stranger is NOT a \
skip -- it is a person with role_guess "unsolicited".
- "gist" is 2-4 sentences on what this thread is about and where it \
stands now -- never a message-by-message narration.
- relationship_kind_guess mirrors the single other persons role_guess for \
a "single" chat, or is the literal string "group" for a "group" chat.
- For chat_type "group", list EVERY non-self participant who sent 2 or \
more messages (name + sender_ids), each with their own role_guess; \
participants with only a single message may be omitted. For a "single" \
chat, list the one counterpart.

Respond with ONLY this JSON object (no prose, no markdown fence), with \
capture_id "%s", chat_id "%s", chat_type "%s" filled in exactly as given:

%s""" % (title, chat_type, thread_text, capture_id, chat_id, chat_type, schema)

sys.stdout.write(prompt)
sys.stderr.write("%s\t%s\t%s\n" % (capture_id, chat_id, chat_type))
' "$event_file"
}

# -----------------------------------------------------------------------
# Validates a parsed summary dict (already loaded from JSON) against
# thread-summary.md 1.0.0's schema. Reads JSON from stdin, prints it back
# to stdout unchanged if valid, exits 4 with a reason on stderr otherwise.
# -----------------------------------------------------------------------
validate_summary() {
    python3 -c '
import json
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write("summarize-thread.sh: model output is not valid JSON: %s\n" % e)
    sys.exit(4)

if not isinstance(data, dict):
    sys.stderr.write("summarize-thread.sh: model output is not a JSON object\n")
    sys.exit(4)

required_top = ["schema_version", "capture_id", "chat_id", "chat_type", "skip",
                 "people", "relationship_kind_guess", "gist", "open_threads",
                 "commitments", "facts"]
missing = [k for k in required_top if k not in data]
if missing:
    sys.stderr.write("summarize-thread.sh: missing required field(s): %s\n" % ", ".join(missing))
    sys.exit(4)

skip = data["skip"]
skip_reasons = {"bot", "broadcast", "self-note", "security-notice", "empty"}
if skip is not None:
    if not isinstance(skip, dict) or skip.get("reason") not in skip_reasons:
        sys.stderr.write("summarize-thread.sh: invalid skip field: %r\n" % (skip,))
        sys.exit(4)

role_enum = {"friend", "family", "colleague", "client", "collaborator",
             "acquaintance", "unsolicited", "unknown"}
people = data["people"]
if not isinstance(people, list):
    sys.stderr.write("summarize-thread.sh: people must be a list\n")
    sys.exit(4)

person_required = {"display_name", "sender_ids", "is_self", "role_guess"}
for i, person in enumerate(people):
    if not isinstance(person, dict) or not person_required.issubset(person.keys()):
        sys.stderr.write("summarize-thread.sh: people[%d] missing required key(s)\n" % i)
        sys.exit(4)
    if person["role_guess"] not in role_enum:
        sys.stderr.write("summarize-thread.sh: people[%d] invalid role_guess: %r\n" % (i, person["role_guess"]))
        sys.exit(4)
    if "message_count" in person:
        mc = person["message_count"]
        if not isinstance(mc, int) or isinstance(mc, bool) or mc < 0:
            sys.stderr.write("summarize-thread.sh: people[%d] invalid message_count: %r\n" % (i, mc))
            sys.exit(4)

kind_enum = role_enum | {"group"}
if data["relationship_kind_guess"] not in kind_enum:
    sys.stderr.write("summarize-thread.sh: invalid relationship_kind_guess: %r\n" % (data["relationship_kind_guess"],))
    sys.exit(4)

facts = data["facts"]
if not isinstance(facts, list):
    sys.stderr.write("summarize-thread.sh: facts must be a list\n")
    sys.exit(4)

provenance_enum = {"told-by-user", "inferred-from-thread"}
for i, fact in enumerate(facts):
    if not isinstance(fact, dict) or "about" not in fact or "text" not in fact or "provenance" not in fact:
        sys.stderr.write("summarize-thread.sh: facts[%d] missing required key(s)\n" % i)
        sys.exit(4)
    if fact["provenance"] not in provenance_enum:
        sys.stderr.write("summarize-thread.sh: facts[%d] invalid provenance: %r\n" % (i, fact["provenance"]))
        sys.exit(4)

commitments = data["commitments"]
if not isinstance(commitments, list):
    sys.stderr.write("summarize-thread.sh: commitments must be a list\n")
    sys.exit(4)
for i, c in enumerate(commitments):
    if not isinstance(c, dict) or "owner" not in c or "what" not in c or "by" not in c:
        sys.stderr.write("summarize-thread.sh: commitments[%d] missing required key(s)\n" % i)
        sys.exit(4)

sys.stdout.write(json.dumps(data))
'
}

# -----------------------------------------------------------------------
# Extracts the `result` field from a claude -p --output-format json file,
# strips a defensive ```json fence, validates it, and prints per the
# above. Factored out so RA_THREAD_PARSE_TEST can exercise it directly.
# -----------------------------------------------------------------------
parse_thread_result() {
    local claude_result_file="$1"

    if [ ! -f "$claude_result_file" ]; then
        echo "summarize-thread.sh: claude result file not found: $claude_result_file" >&2
        return 4
    fi

    # Prefer structured_output -- claude with --json-schema already parses
    # the model's JSON for us there, avoiding a class of bug where the
    # model's own `result` text field stringifies a value it shouldn't
    # (observed live: skip:null in structured_output vs skip:"null" as a
    # literal string in result on a large real thread). Fall back to
    # parsing `result` (with a defensive ```json fence strip) for
    # RA_THREAD_PARSE_TEST fixtures that do not carry structured_output.
    local answer_text
    answer_text=$(python3 -c '
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write("summarize-thread.sh: malformed claude result JSON: %s\n" % e)
    sys.exit(4)

structured = data.get("structured_output")
if isinstance(structured, dict):
    sys.stdout.write(json.dumps(structured))
    sys.exit(0)

result = data.get("result")
if result is None:
    sys.stderr.write("summarize-thread.sh: claude result JSON missing both structured_output and result fields\n")
    sys.exit(4)

sys.stdout.write(str(result))
' "$claude_result_file")
    local extract_status=$?
    if [ "$extract_status" -ne 0 ]; then
        return 4
    fi

    # Strip a defensive ```json ... ``` (or bare ```) fence if present
    # (only ever present on the result-field fallback path, above).
    local stripped
    stripped=$(printf '%s\n' "$answer_text" | sed -e '1{/^```json$/d;}' -e '1{/^```$/d;}' -e '${/^```$/d;}')

    printf '%s\n' "$stripped" | validate_summary
}

# -----------------------------------------------------------------------
# Test hook
# -----------------------------------------------------------------------
if [ -n "${RA_THREAD_PARSE_TEST:-}" ]; then
    out=$(parse_thread_result "$RA_THREAD_PARSE_TEST")
    status=$?
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
    printf '%s\n' "$out"
    exit 0
fi

# -----------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------
event_file=""
model="${RA_THREAD_MODEL:-sonnet}"
out_path=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            model="${2:-}"
            shift 2
            ;;
        --out)
            out_path="${2:-}"
            shift 2
            ;;
        -*)
            echo "summarize-thread.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [ -n "$event_file" ]; then
                echo "summarize-thread.sh: unexpected extra argument: $1" >&2
                exit 2
            fi
            event_file="$1"
            shift
            ;;
    esac
done

if [ -z "$event_file" ]; then
    echo "usage: summarize-thread.sh <event-file> [--model <m>] [--out <path>]" >&2
    exit 2
fi

if [ ! -f "$event_file" ]; then
    echo "summarize-thread.sh: event file not found: $event_file" >&2
    exit 2
fi

timeout_secs="${RA_THREAD_TIMEOUT_SECS:-180}"

meta_file=$(mktemp)
prompt_file=$(mktemp)
trap 'rm -f "$meta_file" "$prompt_file"' EXIT

build_prompt "$event_file" > "$prompt_file" 2> "$meta_file"
build_status=$?
if [ "$build_status" -ne 0 ]; then
    exit 2
fi

thread_prompt=$(cat "$prompt_file")
prompt_bytes=$(wc -c < "$prompt_file" | tr -d ' ')

# Hermetic, neutral run: a fresh work dir with no CLAUDE.md (never the repo
# cwd), an empty --mcp-config so no project MCP server (e.g. a stalled
# Beeper bridge server) is even attempted, and a --json-schema constraining
# the model to this spec's output shape (python still re-validates below —
# the schema flag is a cost-cutting constraint, not the source of truth).
work_dir=$(mktemp -d)
result_file="${work_dir}/result.json"
mcp_config_path="${work_dir}/mcp-config.json"
json_schema_path="${work_dir}/thread-summary.schema.json"
trap 'rm -f "$meta_file" "$prompt_file"; rm -rf "$work_dir"' EXIT

printf '%s\n' '{"mcpServers":{}}' > "$mcp_config_path"
cat > "$json_schema_path" <<'SCHEMA_EOF'
{
  "type": "object",
  "properties": {
    "schema_version": {"type": "string"},
    "capture_id": {"type": "string"},
    "chat_id": {"type": "string"},
    "chat_type": {"type": "string"},
    "skip": {
      "type": ["null", "object"],
      "properties": {
        "reason": {
          "type": "string",
          "enum": ["bot", "broadcast", "self-note", "security-notice", "empty"]
        }
      }
    },
    "people": {"type": "array"},
    "relationship_kind_guess": {"type": "string"},
    "gist": {"type": "string"},
    "open_threads": {"type": "array"},
    "commitments": {"type": "array"},
    "facts": {"type": "array"}
  },
  "required": ["schema_version", "capture_id", "chat_id", "chat_type", "skip",
               "people", "relationship_kind_guess", "gist", "open_threads",
               "commitments", "facts"]
}
SCHEMA_EOF
# --json-schema takes inline JSON, not a path (confirmed against eval-judge.sh's
# JUDGE_SCHEMA usage) -- the file above exists for readability/diffing only.
json_schema="$(cat "$json_schema_path")"

if [ -n "${RA_THREAD_DRY_RUN:-}" ]; then
    printf '%s\n' "$thread_prompt"
    printf -- '---\n'
    printf 'cwd=%s\n' "$work_dir"
    printf 'claude -p <thread-prompt, %s bytes> --strict-mcp-config --mcp-config %s --json-schema %s --max-turns 2 --model %s --output-format json\n' \
        "$prompt_bytes" "$mcp_config_path" "$json_schema_path" "$model"
    exit 0
fi

start_secs=$(date +%s)

(
    cd "$work_dir" || exit 3
    claude -p "$thread_prompt" \
        --strict-mcp-config \
        --mcp-config "$mcp_config_path" \
        --json-schema "$json_schema" \
        --max-turns 2 \
        --model "$model" \
        --output-format json \
        < /dev/null \
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

end_secs=$(date +%s)
elapsed_secs=$((end_secs - start_secs))

if [ "$claude_status" -ne 0 ]; then
    echo "summarize-thread.sh: claude -p exited non-zero ($claude_status) or timed out after ${elapsed_secs}s (limit ${timeout_secs}s, prompt ${prompt_bytes} bytes)" >&2
    exit 3
fi

summary_json=$(parse_thread_result "$result_file")
validate_status=$?
if [ "$validate_status" -ne 0 ]; then
    exit "$validate_status"
fi

# Usage line (stderr only): today's one visibility hook into per-call cost/
# token spend, otherwise discarded. Never fatal -- a malformed/missing
# result_file field prints "?" rather than aborting a good summary.
python3 -c '
import json
import sys

result_file, summary_json_text, elapsed, model = sys.argv[1:5]

capture_id = "?"
try:
    capture_id = json.loads(summary_json_text).get("capture_id", "?")
except Exception:
    pass

cost = "?"
tokens_in = "?"
tokens_out = "?"
try:
    with open(result_file) as f:
        result_data = json.load(f)
    cost = result_data.get("total_cost_usd", "?")
    usage = result_data.get("usage", {}) or {}
    input_tokens = usage.get("input_tokens", 0) or 0
    cache_read_tokens = usage.get("cache_read_input_tokens", 0) or 0
    tokens_in = input_tokens + cache_read_tokens
    tokens_out = usage.get("output_tokens", "?")
except Exception:
    pass

sys.stderr.write(
    "summarize-thread: %s model=%s secs=%s cost_usd=%s in=%s out=%s\n"
    % (capture_id, model, elapsed, cost, tokens_in, tokens_out)
)
' "$result_file" "$summary_json" "$elapsed_secs" "$model"

if [ -n "$out_path" ]; then
    printf '%s\n' "$summary_json" > "$out_path"
else
    printf '%s\n' "$summary_json"
fi

exit 0
