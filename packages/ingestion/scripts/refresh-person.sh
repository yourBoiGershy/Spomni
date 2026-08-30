#!/usr/bin/env bash
# refresh-person.sh — one-shot, hermetic model call that re-derives a
# person's inferred facts and open/resolved threads from their FULL
# interaction timeline, so person.md says where things stand now
# (packages/ingestion/specs/currency.md, plan 36 A4). Mirrors
# scripts/summarize-thread.sh's transport (claude -p --output-format json,
# backgrounded sleep-and-kill watchdog, --json-schema constraint, python3
# heredoc helpers) but the input is a person's whole history, not one
# thread, and the output writes person.md directly rather than handing a
# summary to a separate filer.
#
# Usage:
#   refresh-person.sh <store-dir> <slug> [--data-dir <dir>] [--dry-run]
#                      [--model <m>]
#
# <store-dir> holds people/, interactions/. --data-dir defaults to
# "<store-dir>/.." and roots the ledger at <data-dir>/ingestion/refresh.log.
# --dry-run runs the model call (or RA_REFRESH_PARSE_TEST parse) normally
# but prints the would-be ## Facts / ## Open threads / ## Resolved sections
# instead of writing person.md or appending to refresh.log.
#
# Prompt input: the person's current ## Facts (all bullets, told-by-user
# ones marked KEEP -- do not restate/return), ## Open threads, ## Resolved,
# frontmatter name/org/role, and every interactions/*.md whose `people:`
# list contains [[slug]], date-ascending (date + ## Summary body). Capped
# at ~60KB total -- oldest interaction bodies are dropped first, replaced
# by a single leading "earlier: <date>, <date>, ..." line so their dates
# are never lost even when their content is.
#
# Write rules (person.md 1.4.0, specs/currency.md): rewrites ONLY the
# inferred-* bullets in ## Facts (told-by-user bullets kept byte-identical,
# in their original relative order, first; inferred bullets from this pass
# appended after, fully replacing the prior inferred set); ## Open threads
# becomes exactly the returned open threads, `- <text> (as-of <as_of>)`;
# ## Resolved becomes the union (verbatim-text dedup) of any existing
# Resolved bullets and the returned ones, `- <text> (resolved <resolved_on>)`
# -- created between Open threads and Personal details if it doesn't exist
# yet. ## Personal details and all frontmatter fields are untouched. A
# stale inferred fact renders `- **[<tag>]** [stale] <text>`. Re-running
# with the same result JSON is a byte-identical no-op.
#
# Env:
#   RA_REFRESH_MODEL          model override (default: sonnet)
#   RA_REFRESH_TIMEOUT_SECS   wall-clock guard in seconds (default: 180)
#   RA_REFRESH_DRY_RUN=1      print the prompt + claude command, exit 0
#                              (transport-level dry run -- no model call,
#                              no write; distinct from the --dry-run flag,
#                              which still calls the model / parse-test but
#                              skips the person.md write)
#   RA_REFRESH_PARSE_TEST=<file>  test-only: skip the claude call, parse
#                                <file> as the claude-result JSON, validate
#                                and apply/print via the normal path
#
# Exit codes:
#   0  person.md refreshed (or --dry-run sections printed), schema-valid
#   2  usage error (including an unexpected person.md section shape)
#   3  claude -p exited non-zero or timed out
#   4  model output failed schema validation (reason on stderr)
#
# Portable to bash 3.2. No timeout(1) -- backgrounded sleep-and-kill
# watchdog, mirrors packages/core/scripts/eval-judge.sh and
# scripts/summarize-thread.sh.

set -u

# -----------------------------------------------------------------------
# Builds the re-derivation prompt from the person's current file +
# every linked interaction. Prints the prompt to stdout.
# -----------------------------------------------------------------------
build_prompt() {
    local store_dir="$1"
    local slug="$2"

    python3 - "$store_dir" "$slug" <<'PYEOF'
import os
import re
import sys

store_dir, slug = sys.argv[1], sys.argv[2]
person_path = os.path.join(store_dir, "people", "%s.md" % slug)

with open(person_path) as f:
    raw = f.read()

m = re.match(r"^---\n(.*?)\n---\n(.*)$", raw, re.DOTALL)
if not m:
    sys.stderr.write("refresh-person.sh: person file missing frontmatter block\n")
    sys.exit(2)

fm_text, body_text = m.group(1), m.group(2)


def fm_field(field):
    fm = re.search(r"^" + re.escape(field) + r":[ \t]*(.*)$", fm_text, re.MULTILINE)
    return fm.group(1).strip().strip('"') if fm else ""


name = fm_field("name")
org = fm_field("org")
role = fm_field("role")


def section_body(text, heading):
    pattern = r"^## " + re.escape(heading) + r"\n\n(.*?)(?=\n\n## |\Z)"
    sm = re.search(pattern, text, re.DOTALL | re.MULTILINE)
    return sm.group(1).strip() if sm else ""


facts_body = section_body(body_text, "Facts")
open_body = section_body(body_text, "Open threads")
resolved_body = section_body(body_text, "Resolved")

facts_lines = [l for l in facts_body.splitlines() if l.strip() and l.strip() != "_none_"]
open_lines = [l for l in open_body.splitlines() if l.strip() and l.strip() != "_none_"]
resolved_lines = [l for l in resolved_body.splitlines() if l.strip() and l.strip() != "_none_"]

facts_context_lines = []
for line in facts_lines:
    if line.startswith("- **[told-by-user]**"):
        facts_context_lines.append(line + "  (KEEP -- do not restate, do not return)")
    else:
        facts_context_lines.append(line)
facts_context = "\n".join(facts_context_lines) if facts_context_lines else "_none_"
open_context = "\n".join(open_lines) if open_lines else "_none_"
resolved_context = "\n".join(resolved_lines) if resolved_lines else "_none_"

# --- interactions linked to this slug, date ascending ---
interactions_dir = os.path.join(store_dir, "interactions")
link = "[[%s]]" % slug
entries = []  # [{"date": ..., "text": ...}]
if os.path.isdir(interactions_dir):
    for fn in sorted(os.listdir(interactions_dir)):
        if not fn.endswith(".md"):
            continue
        path = os.path.join(interactions_dir, fn)
        with open(path) as f:
            iraw = f.read()
        im = re.match(r"^---\n(.*?)\n---\n(.*)$", iraw, re.DOTALL)
        if not im:
            continue
        ifm_text, ibody_text = im.group(1), im.group(2)
        people_m = re.search(r"^people:[ \t]*(.*)$", ifm_text, re.MULTILINE)
        people_val = people_m.group(1) if people_m else ""
        if link not in people_val:
            continue
        date_m = re.search(r"^date:[ \t]*(.*)$", ifm_text, re.MULTILINE)
        date = date_m.group(1).strip().strip('"') if date_m else ""
        sm = re.search(r"## Summary\n\n(.*?)(?=\n\n## |\Z)", ibody_text, re.DOTALL)
        summary_text = sm.group(1).strip() if sm else ""
        entries.append({"date": date, "text": summary_text})

entries.sort(key=lambda e: e["date"])

CAP_BYTES = 60000


def render(blocks):
    return "\n\n".join("### %s\n%s" % (b["date"], b["text"]) for b in blocks)


blocks = list(entries)
full_text = render(blocks)
dropped_dates = []
while blocks and len(full_text.encode("utf-8")) > CAP_BYTES:
    dropped_dates.append(blocks[0]["date"])
    blocks = blocks[1:]
    full_text = render(blocks)

earlier_line = ""
if dropped_dates:
    earlier_line = "earlier: " + ", ".join(dropped_dates) + "\n\n"

timeline_text = (earlier_line + full_text) if full_text else (earlier_line.rstrip() or "_none_")

person_line = name or slug
if role:
    person_line = person_line + " (%s)" % role
if org:
    person_line = person_line + " -- %s" % org

schema = """{
  "schema_version": "1.0.0",
  "slug": "<slug>",
  "facts": [{"provenance": "inferred-from-thread|inferred-public-web", "text": str, "stale": bool}],
  "open_threads": [{"text": str, "as_of": "YYYY-MM-DD"}],
  "resolved": [{"text": str, "resolved_on": "YYYY-MM-DD"}]
}"""

prompt = """You are re-deriving where things stand right now with %s, from \
their full interaction timeline -- invent nothing; only re-derive \
inferred-* facts and the open/resolved thread set from what the timeline \
actually shows.

Current Facts (context -- told-by-user bullets are fixed and must never be \
returned; only re-derive the inferred-* bullets):
%s

Current Open threads (context):
%s

Current Resolved (context):
%s

Interaction timeline (chronological, oldest first; a leading "earlier: \
<dates>" line lists dates whose bodies were dropped to stay within the \
prompt budget -- never invent content for those dates):
%s

Rules:
- Never invent facts. Only return facts with provenance "inferred-from-thread" \
(inferred from something said/done in one of these interactions) or \
"inferred-public-web" (inferred from public context implied by the \
timeline) -- never "told-by-user".
- Mark a fact "stale": true if the timeline suggests it may no longer be \
current but you are not certain enough to drop it outright; "stale": false \
otherwise.
- "open_threads" is what's still live right now -- questions asked, topics \
promised, loose ends not yet closed by a later interaction. Each thread's \
"as_of" is the date of the interaction that LAST evidenced it (not \
necessarily the most recent interaction overall).
- A thread closed by a later interaction moves to "resolved" with \
"resolved_on" set to the date of the interaction that closed it -- it must \
NOT also appear in "open_threads".
- Write everything from the perspective of where things stand NOW, never a \
message-by-message or day-by-day narration.

Respond with ONLY this JSON object (no prose, no markdown fence), with \
schema_version "1.0.0" and slug "%s" filled in exactly as given:

%s""" % (
    person_line,
    facts_context,
    open_context,
    resolved_context,
    timeline_text,
    slug,
    schema,
)

sys.stdout.write(prompt)
PYEOF
}

# -----------------------------------------------------------------------
# Validates a parsed refresh dict (already loaded from JSON) against this
# script's schema. Reads JSON from stdin, prints it back to stdout
# unchanged if valid, exits 4 with a reason on stderr otherwise. Stdin is
# spooled to a temp file first -- `python3 - <<'PYEOF'` uses the heredoc as
# the script's own source (stdin), so a piped stdin would otherwise never
# reach the script's sys.stdin.read().
# -----------------------------------------------------------------------
validate_refresh() {
    local stdin_file
    stdin_file=$(mktemp)
    cat > "$stdin_file"

    python3 - "$stdin_file" <<'PYEOF'
import json
import re
import sys

with open(sys.argv[1]) as f:
    raw = f.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write("refresh-person.sh: model output is not valid JSON: %s\n" % e)
    sys.exit(4)

if not isinstance(data, dict):
    sys.stderr.write("refresh-person.sh: model output is not a JSON object\n")
    sys.exit(4)

required = ["schema_version", "slug", "facts", "open_threads", "resolved"]
missing = [k for k in required if k not in data]
if missing:
    sys.stderr.write("refresh-person.sh: missing required field(s): %s\n" % ", ".join(missing))
    sys.exit(4)

if data.get("schema_version") != "1.0.0":
    sys.stderr.write("refresh-person.sh: unsupported schema_version: %r\n" % (data.get("schema_version"),))
    sys.exit(4)

if not isinstance(data.get("slug"), str) or not data["slug"]:
    sys.stderr.write("refresh-person.sh: slug must be a non-empty string\n")
    sys.exit(4)

date_re = re.compile(r"^\d{4}-\d{2}-\d{2}$")
provenance_enum = {"inferred-from-thread", "inferred-public-web"}

facts = data["facts"]
if not isinstance(facts, list):
    sys.stderr.write("refresh-person.sh: facts must be a list\n")
    sys.exit(4)
for i, fact in enumerate(facts):
    if not isinstance(fact, dict) or "provenance" not in fact or "text" not in fact or "stale" not in fact:
        sys.stderr.write("refresh-person.sh: facts[%d] missing required key(s)\n" % i)
        sys.exit(4)
    if fact["provenance"] not in provenance_enum:
        sys.stderr.write("refresh-person.sh: facts[%d] invalid provenance: %r\n" % (i, fact["provenance"]))
        sys.exit(4)
    if not isinstance(fact["text"], str) or not fact["text"].strip():
        sys.stderr.write("refresh-person.sh: facts[%d] text must be a non-empty string\n" % i)
        sys.exit(4)
    if not isinstance(fact["stale"], bool):
        sys.stderr.write("refresh-person.sh: facts[%d] stale must be a boolean\n" % i)
        sys.exit(4)

open_threads = data["open_threads"]
if not isinstance(open_threads, list):
    sys.stderr.write("refresh-person.sh: open_threads must be a list\n")
    sys.exit(4)
for i, t in enumerate(open_threads):
    if not isinstance(t, dict) or "text" not in t or "as_of" not in t:
        sys.stderr.write("refresh-person.sh: open_threads[%d] missing required key(s)\n" % i)
        sys.exit(4)
    if not isinstance(t["text"], str) or not t["text"].strip():
        sys.stderr.write("refresh-person.sh: open_threads[%d] text must be a non-empty string\n" % i)
        sys.exit(4)
    if not isinstance(t["as_of"], str) or not date_re.match(t["as_of"]):
        sys.stderr.write("refresh-person.sh: open_threads[%d] invalid as_of: %r\n" % (i, t["as_of"]))
        sys.exit(4)

resolved = data["resolved"]
if not isinstance(resolved, list):
    sys.stderr.write("refresh-person.sh: resolved must be a list\n")
    sys.exit(4)
for i, r in enumerate(resolved):
    if not isinstance(r, dict) or "text" not in r or "resolved_on" not in r:
        sys.stderr.write("refresh-person.sh: resolved[%d] missing required key(s)\n" % i)
        sys.exit(4)
    if not isinstance(r["text"], str) or not r["text"].strip():
        sys.stderr.write("refresh-person.sh: resolved[%d] text must be a non-empty string\n" % i)
        sys.exit(4)
    if not isinstance(r["resolved_on"], str) or not date_re.match(r["resolved_on"]):
        sys.stderr.write("refresh-person.sh: resolved[%d] invalid resolved_on: %r\n" % (i, r["resolved_on"]))
        sys.exit(4)

sys.stdout.write(json.dumps(data))
PYEOF
    local status=$?
    rm -f "$stdin_file"
    return "$status"
}

# -----------------------------------------------------------------------
# Extracts the `result` field from a claude -p --output-format json file,
# strips a defensive ```json fence, validates it, and prints per the
# above. Factored out so RA_REFRESH_PARSE_TEST can exercise it directly.
# -----------------------------------------------------------------------
parse_refresh_result() {
    local claude_result_file="$1"

    if [ ! -f "$claude_result_file" ]; then
        echo "refresh-person.sh: claude result file not found: $claude_result_file" >&2
        return 4
    fi

    local answer_text
    answer_text=$(python3 - "$claude_result_file" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write("refresh-person.sh: malformed claude result JSON: %s\n" % e)
    sys.exit(4)

structured = data.get("structured_output")
if isinstance(structured, dict):
    sys.stdout.write(json.dumps(structured))
    sys.exit(0)

result = data.get("result")
if result is None:
    sys.stderr.write("refresh-person.sh: claude result JSON missing both structured_output and result fields\n")
    sys.exit(4)

sys.stdout.write(str(result))
PYEOF
)
    local extract_status=$?
    if [ "$extract_status" -ne 0 ]; then
        return 4
    fi

    local stripped
    stripped=$(printf '%s\n' "$answer_text" | sed -e '1{/^```json$/d;}' -e '1{/^```$/d;}' -e '${/^```$/d;}')

    printf '%s\n' "$stripped" | validate_refresh
}

# -----------------------------------------------------------------------
# Applies a validated refresh JSON to person.md: rewrites the inferred-*
# ## Facts bullets, replaces ## Open threads wholesale, and unions
# ## Resolved. --dry-run (write_dry_run=1) prints the would-be sections
# instead of writing. Prints the one summary line either way.
# -----------------------------------------------------------------------
apply_refresh() {
    local store_dir="$1"
    local slug="$2"
    local data_dir="$3"
    local refresh_json_file="$4"
    local write_dry_run="$5"

    python3 - "$store_dir" "$slug" "$data_dir" "$refresh_json_file" "$write_dry_run" <<'PYEOF'
import datetime
import json
import os
import re
import sys

store_dir, slug, data_dir, refresh_json_file, write_dry_run_arg = sys.argv[1:6]
WRITE_DRY_RUN = write_dry_run_arg == "1"

with open(refresh_json_file) as f:
    data = json.load(f)

person_path = os.path.join(store_dir, "people", "%s.md" % slug)
with open(person_path) as f:
    content = f.read()

facts_m = re.search(r"(## Facts\n\n)(.*?)(\n\n## Open threads)", content, re.DOTALL)
if not facts_m:
    sys.stderr.write("refresh-person.sh: person file missing ## Facts section in the expected shape\n")
    sys.exit(2)

facts_block = facts_m.group(2)
facts_lines = [l for l in facts_block.splitlines() if l.strip() and l.strip() != "_none_"]
told_by_user_lines = [l for l in facts_lines if l.startswith("- **[told-by-user]**")]


def render_fact(fact):
    stale_marker = "[stale] " if fact.get("stale") else ""
    return "- **[%s]** %s%s" % (fact["provenance"], stale_marker, fact["text"])


new_inferred_lines = [render_fact(f) for f in data["facts"]]
new_facts_lines = told_by_user_lines + new_inferred_lines
new_facts_block = "\n".join(new_facts_lines) if new_facts_lines else "_none_"

open_m = re.search(
    r"## Open threads\n\n(.*?)\n\n(?:## Resolved\n\n(.*?)\n\n)?## Personal details",
    content,
    re.DOTALL,
)
if not open_m:
    sys.stderr.write("refresh-person.sh: person file missing ## Open threads section in the expected shape\n")
    sys.exit(2)

existing_resolved_body = open_m.group(2)
existing_resolved_lines = (
    []
    if existing_resolved_body is None
    else [l for l in existing_resolved_body.splitlines() if l.strip() and l.strip() != "_none_"]
)

new_open_lines = ["- %s (as-of %s)" % (t["text"], t["as_of"]) for t in data["open_threads"]]
new_open_block = "\n".join(new_open_lines) if new_open_lines else "_none_"

returned_resolved_lines = ["- %s (resolved %s)" % (r["text"], r["resolved_on"]) for r in data["resolved"]]

combined_resolved_lines = list(existing_resolved_lines)
for line in returned_resolved_lines:
    if line not in combined_resolved_lines:
        combined_resolved_lines.append(line)

resolved_block = ("## Resolved\n\n" + "\n".join(combined_resolved_lines) + "\n\n") if combined_resolved_lines else ""

counts = {
    "facts": len(data["facts"]),
    "stale": sum(1 for f in data["facts"] if f.get("stale")),
    "open": len(data["open_threads"]),
    "resolved": len(data["resolved"]),
}

if WRITE_DRY_RUN:
    sys.stdout.write(
        "## Facts\n\n%s\n\n## Open threads\n\n%s\n\n%s## Personal details\n"
        % (new_facts_block, new_open_block, resolved_block)
    )
    print(
        "refresh-person: %s facts=%d stale=%d open=%d resolved=%d"
        % (slug, counts["facts"], counts["stale"], counts["open"], counts["resolved"])
    )
    sys.exit(0)

content = content[: facts_m.start(2)] + new_facts_block + content[facts_m.end(2) :]

# Facts section length may have changed -- re-match Open threads on the
# already-updated content before splicing it too.
open_m2 = re.search(
    r"## Open threads\n\n(.*?)\n\n(?:## Resolved\n\n(.*?)\n\n)?## Personal details",
    content,
    re.DOTALL,
)
replacement = "## Open threads\n\n%s\n\n%s## Personal details" % (new_open_block, resolved_block)
content = content[: open_m2.start()] + replacement + content[open_m2.end() :]

with open(person_path, "w") as f:
    f.write(content)

ing_dir = os.path.join(data_dir, "ingestion")
os.makedirs(ing_dir, exist_ok=True)
log_path = os.path.join(ing_dir, "refresh.log")
now_iso = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
with open(log_path, "a") as f:
    f.write(
        "%s\t%s\tfacts=%d open=%d resolved=%d\n"
        % (slug, now_iso, counts["facts"], counts["open"], counts["resolved"])
    )

print(
    "refresh-person: %s facts=%d stale=%d open=%d resolved=%d"
    % (slug, counts["facts"], counts["stale"], counts["open"], counts["resolved"])
)
PYEOF
}

# -----------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------
store_dir=""
slug=""
model="${RA_REFRESH_MODEL:-sonnet}"
data_dir=""
cli_dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir)
            data_dir="${2:-}"
            shift 2
            ;;
        --dry-run)
            cli_dry_run=1
            shift
            ;;
        --model)
            model="${2:-}"
            shift 2
            ;;
        -*)
            echo "refresh-person.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [ -z "$store_dir" ]; then
                store_dir="$1"
            elif [ -z "$slug" ]; then
                slug="$1"
            else
                echo "refresh-person.sh: unexpected extra argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [ -z "$store_dir" ] || [ -z "$slug" ]; then
    echo "usage: refresh-person.sh <store-dir> <slug> [--data-dir <dir>] [--dry-run] [--model <m>]" >&2
    exit 2
fi

if [ ! -d "${store_dir}/people" ]; then
    echo "refresh-person.sh: ${store_dir}/people: no such directory" >&2
    exit 2
fi

person_file="${store_dir}/people/${slug}.md"
if [ ! -f "$person_file" ]; then
    echo "refresh-person.sh: person file not found: $person_file" >&2
    exit 2
fi

[ -n "$data_dir" ] || data_dir="${store_dir}/.."

timeout_secs="${RA_REFRESH_TIMEOUT_SECS:-180}"

# -----------------------------------------------------------------------
# Test hook: skip the claude call, parse a canned result file.
# -----------------------------------------------------------------------
if [ -n "${RA_REFRESH_PARSE_TEST:-}" ]; then
    refresh_json=$(parse_refresh_result "$RA_REFRESH_PARSE_TEST")
    status=$?
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
    refresh_json_file=$(mktemp)
    trap 'rm -f "$refresh_json_file"' EXIT
    printf '%s\n' "$refresh_json" > "$refresh_json_file"
    apply_refresh "$store_dir" "$slug" "$data_dir" "$refresh_json_file" "$cli_dry_run"
    exit $?
fi

prompt_file=$(mktemp)
meta_file=$(mktemp)
trap 'rm -f "$prompt_file" "$meta_file"' EXIT

build_prompt "$store_dir" "$slug" > "$prompt_file" 2> "$meta_file"
build_status=$?
if [ "$build_status" -ne 0 ]; then
    cat "$meta_file" >&2
    exit 2
fi

refresh_prompt=$(cat "$prompt_file")
prompt_bytes=$(wc -c < "$prompt_file" | tr -d ' ')

# Hermetic, neutral run: a fresh work dir with no CLAUDE.md (never the repo
# cwd), an empty --mcp-config so no project MCP server is even attempted,
# and a --json-schema constraining the model to this script's output shape
# (python still re-validates below -- the schema flag is a cost-cutting
# constraint, not the source of truth).
work_dir=$(mktemp -d)
result_file="${work_dir}/result.json"
mcp_config_path="${work_dir}/mcp-config.json"
json_schema_path="${work_dir}/refresh-person.schema.json"
trap 'rm -f "$prompt_file" "$meta_file"; rm -rf "$work_dir"' EXIT

printf '%s\n' '{"mcpServers":{}}' > "$mcp_config_path"
cat > "$json_schema_path" <<'SCHEMA_EOF'
{
  "type": "object",
  "properties": {
    "schema_version": {"type": "string"},
    "slug": {"type": "string"},
    "facts": {"type": "array"},
    "open_threads": {"type": "array"},
    "resolved": {"type": "array"}
  },
  "required": ["schema_version", "slug", "facts", "open_threads", "resolved"]
}
SCHEMA_EOF
json_schema="$(cat "$json_schema_path")"

if [ -n "${RA_REFRESH_DRY_RUN:-}" ]; then
    printf '%s\n' "$refresh_prompt"
    printf -- '---\n'
    printf 'cwd=%s\n' "$work_dir"
    printf 'claude -p <refresh-prompt, %s bytes> --strict-mcp-config --mcp-config %s --json-schema %s --max-turns 2 --model %s --output-format json\n' \
        "$prompt_bytes" "$mcp_config_path" "$json_schema_path" "$model"
    exit 0
fi

start_secs=$(date +%s)

(
    cd "$work_dir" || exit 3
    claude -p "$refresh_prompt" \
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
    echo "refresh-person.sh: claude -p exited non-zero ($claude_status) or timed out after ${elapsed_secs}s (limit ${timeout_secs}s, prompt ${prompt_bytes} bytes)" >&2
    exit 3
fi

refresh_json=$(parse_refresh_result "$result_file")
validate_status=$?
if [ "$validate_status" -ne 0 ]; then
    exit "$validate_status"
fi

# Usage line (stderr only): today's one visibility hook into per-call cost/
# token spend, otherwise discarded. Never fatal.
python3 - "$result_file" "$slug" "$elapsed_secs" "$model" <<'PYEOF'
import json
import sys

result_file, slug, elapsed, model = sys.argv[1:5]

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
    "refresh-person: %s model=%s secs=%s cost_usd=%s in=%s out=%s\n"
    % (slug, model, elapsed, cost, tokens_in, tokens_out)
)
PYEOF

refresh_json_file="${work_dir}/refresh.json"
printf '%s\n' "$refresh_json" > "$refresh_json_file"
apply_refresh "$store_dir" "$slug" "$data_dir" "$refresh_json_file" "$cli_dry_run"
exit $?
