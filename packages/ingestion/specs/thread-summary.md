# Spec: thread summary

`schema_version: 1.0.0`

Status: spec (plan 32 D1). Package: `packages/ingestion`. Implemented by
`packages/ingestion/scripts/summarize-thread.sh`. Mission test: one headless
model call per chat thread replaces per-day agentic filing of the same
thread — a running-cost cut, not a substitute for the user's own judgment
about the people in it. Every fact this spec's output carries a provenance
tag; the model is never allowed to invent one.

## Problem

A chat thread (WhatsApp/iMessage/etc, captured as a `chat-message` capture
event per `contracts/capture-event.md` 1.2.0) currently gets re-read message
by message every time the debrief skill visits it. Threads are small (max
~75 KB) — one model call can read the whole thread once and emit a compact,
structured summary that downstream filing (`file-thread.sh`, a separate
unit) consumes instead of re-reading raw messages. This spec is that one
call's contract: input shape, prompt rules, and output schema.

## Input

A `chat-message` capture event file: YAML frontmatter (`id`, `source:
beeper-in/<network>` or `beeper`, `type: chat-message`, `participant-hints`)
followed by a single-line JSON body:

```
{"chatID","accountID","network","title","chatType":"single|group",
 "messages":[{"id","senderID","senderName","timestamp":"2026-08-29T18:57:25.000Z",
              "type":"TEXT|NOTICE|...","text","isSender":true|false, ...}]}
```

`isSender` may appear as a JSON boolean (`true`/`false`) or as the string
`"True"`/`"False"` depending on capture source generation — both are
accepted identically.

## Prompt construction

Before prompting, drop from the message list, in this order:
1. any message with `type: NOTICE` (or any other non-content system-row
   type distinct from ordinary content types),
2. any message flagged deleted (`isDeleted: true`/`"True"`),
3. any remaining message with no non-empty `text` (e.g. a bare reaction row
   with no text of its own — nothing to summarize from it).

Each surviving message compacts to one line:
`[<timestamp>] <senderName> (self|other): <text>` — `self` when `isSender`
is truthy, `other` otherwise. The compacted thread, the chat's `title`/
`chatType`, and the output schema (below) go into one prompt that instructs
the model:

- The `isSender: true` party is "the user" — never referred to by name in
  the prompt's own framing (a `senderName` may still say the user's own
  name inside message text; that's fine, it's just data).
  never invent facts: `told-by-user` provenance is reserved for things the
  user literally wrote about themselves or the other person; anything the
  model concludes from tone/context/behavior is `inferred-from-thread`.
- `skip` is reserved for threads with **no person on the other end** — a
  bot, a broadcast/announcement channel (e.g. "Beeper Updates"), a
  self-chat ("Note to self"), or a security/OTP notice channel. A cold
  pitch from an actual stranger is **not** a skip — it is a person with
  `role_guess: unsolicited` (plan 32 D4: the model must not use `skip` as
  an escape hatch for "I don't know this person").
- `gist` is 2-4 sentences describing what the thread is about and where it
  currently stands — never a message-by-message narration.
- For `chat_type: group`, list **every** non-self participant who sent 2 or
  more messages (name + `sender_ids`), each with their own `role_guess` —
  a participant with only a single message may be omitted. For a `single`
  chat, list the one counterpart. (Group threads were previously
  under-listing to one or two people, starving the filing writer of
  participants — this rule is the fix.)
- The model must return **only** the JSON object described below — no
  prose before or after it. The script strips a defensive ```json fence if
  the model wraps the object in one anyway.

## Output schema (1.0.0)

```json
{
  "schema_version": "1.0.0",
  "capture_id": "<id from frontmatter>",
  "chat_id": "<chatID>",
  "chat_type": "single|group",
  "skip": null,
  "people": [
    {
      "display_name": "string",
      "sender_ids": ["string"],
      "is_self": false,
      "role_guess": "friend|family|colleague|client|collaborator|acquaintance|unsolicited|unknown",
      "message_count": 0
    }
  ],
  "relationship_kind_guess": "friend|family|colleague|client|collaborator|acquaintance|unsolicited|unknown|group",
  "gist": "string, 2-4 sentences",
  "open_threads": ["string"],
  "commitments": [
    {"owner": "user|<display_name>", "what": "string", "by": "string|null"}
  ],
  "facts": [
    {"about": "<display_name>|user", "text": "string", "provenance": "told-by-user|inferred-from-thread"}
  ]
}
```

Or, when the thread is a skip:

```json
{
  "schema_version": "1.0.0",
  "capture_id": "<id from frontmatter>",
  "chat_id": "<chatID>",
  "chat_type": "single|group",
  "skip": {"reason": "bot|broadcast|self-note|security-notice|empty"},
  "people": [], "relationship_kind_guess": "unknown", "gist": "",
  "open_threads": [], "commitments": [], "facts": []
}
```

`relationship_kind_guess` is the thread-level enum: for a `single` chat it
mirrors the single other person's `role_guess`; for a `group` chat it is
always the literal string `"group"` (individual members still get their own
`role_guess` in `people[]`).

`skip.reason: "empty"` covers a thread with zero surviving messages after
the drop rules above (e.g. every message was a NOTICE row) — there is
nothing to summarize, and no person to name.

The script validates this shape with `python3` before printing it (or
writing it to `--out`): required top-level keys present, `skip` is either
`null` or an object with a `reason` in the fixed set above, every `people[]`
entry has the four required keys (`display_name`, `sender_ids`, `is_self`,
`role_guess`) with `role_guess` in the fixed enum, plus an optional
`message_count` (non-negative integer, when present), every `facts[]`
entry's `provenance` in `{told-by-user, inferred-from-thread}`.
Any violation prints the specific reason to stderr and exits `4` — nothing
partial is printed to stdout in that case.

## CLI

```
summarize-thread.sh <event-file> [--model <m>] [--out <path>]
```

Prints the validated summary JSON to stdout, or to `<path>` when `--out` is
given (in which case nothing goes to stdout except on error).

### Invocation isolation

The `claude -p` call runs from a fresh `mktemp -d` work dir — never the repo
cwd — with no `CLAUDE.md` in scope, `--strict-mcp-config --mcp-config
<path>` pointing at a work-dir-local `{"mcpServers":{}}` file (no MCP server,
including any misbehaving one like a stalled Beeper bridge server, is ever
started), and `--json-schema <inline schema>` constraining the model to this
spec's top-level output shape (mirrors `eval-run.sh`'s hermetic-workspace
pattern and `eval-judge.sh`'s `JUDGE_SCHEMA` inline-JSON convention — the
flag takes inline JSON, not a file path). `--max-turns 2` (one turn plus one
schema-conformance retry the model sometimes needs on larger threads;
`--max-turns 1` was tried first and failed `terminal_reason: max_turns` on a
63-message real thread). The parse step prefers the `claude -p --output-format
json` result's `structured_output` field (already schema-parsed) over its
`result` text field, falling back to `result` only when `structured_output`
is absent — a live run showed the model can stringify an ambiguous field
(`skip:"null"` as text) in `result` while `structured_output` carries the
real JSON `null`; the `skip` schema property is further constrained to
`type: ["null", "object"]` to close that ambiguity at the source. The
per-thread python schema validation described above still runs regardless
— the `--json-schema` flag and the tightened `skip` type are cost-cutting
constraints on the model, never the source of truth.

### Env

| Var | Default | Meaning |
|---|---|---|
| `RA_THREAD_MODEL` | `sonnet` | `claude -p --model` value -- sonnet is both faster and more schema-reliable than haiku on this call; haiku selectable via `RA_THREAD_MODEL=haiku` |
| `RA_THREAD_TIMEOUT_SECS` | `180` | wall-clock guard (sleep-and-kill backgrounded watchdog, no `timeout(1)` — bash 3.2/BSD portability, mirrors `eval-judge.sh`); on timeout/non-zero exit the error line reports elapsed seconds, the configured limit, and the prompt's byte size |
| `RA_THREAD_DRY_RUN=1` | unset | print the constructed prompt, the work dir, and the full `claude -p` command (including `--strict-mcp-config`/`--mcp-config`/`--json-schema`/`--max-turns`) that would run, then exit 0 — no model call |
| `RA_THREAD_PARSE_TEST=<claude-result.json>` | unset | skip the model call; parse `<file>` as if it were the `claude -p --output-format json` result (`structured_output` preferred, `result` as fallback), validate, and print/exit via the normal path — the only way tests exercise validation without a live call |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | summary printed (or written to `--out`), schema-valid |
| 2 | usage error (missing/unreadable event file, bad flag) |
| 3 | `claude -p` exited non-zero or the timeout watchdog killed it |
| 4 | model output failed schema validation (reason on stderr) |

## Out of scope

- Filing the summary into `people/`/`interactions/` — a separate unit
  (`file-thread.sh`) consumes this script's output; this spec only covers
  producing it. That unit's dedup pass identifies a capture as chat-eligible
  by its BODY shape (a `chatID` key plus a `messages` array), not by its
  `type` field, so legacy `source: beeper`/`type: other` captures carrying
  the same chat body are folded in too.
- Any model call other than the single summarization call per thread.
- Threads over the ~75 KB size the beeper lane already caps chat exports
  at — no chunking/pagination here.
