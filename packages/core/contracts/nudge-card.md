# Contract: nudge-card

`schema_version: 1.0.0`

## Purpose

Turns one fired wake-up batch (`packages/attention/scripts/wakeup-queue.sh
fire`'s batch artifact, `wakeups/fired/<today>T<HHMMSS>Z-batch.json`) into a
single plain-text chat message: numbered cards the human can reply to
inline. This is the last mile of `wakeup-queue-over-digests` — the queue
decides *what* and *when*; this contract decides how it reads as one message
a human can act on without opening a UI. Mission test: cuts *remembering-to*
(the human doesn't have to hold pending follow-ups in their head or dig
through a dashboard); it never substitutes for the human's own words —
drafts are always marked unsent, and nothing here scores, shames, or nags.

## Writer / readers

- **Sole writer:** `packages/core` (`scripts/render-nudge-cards.sh`). Read-only,
  stateless — takes a batch JSON file and produces text; never mutates the
  wakeup queue.
- **Callers:** `packages/connectors` (`deliver-tick.sh`, forward-declared),
  which hands the rendered text to whichever output adapter is configured.
- **Consumers:** every output adapter (chat surface, etc.) — they render the
  returned plain text verbatim; none of them re-derive card text.

## Input

The `fire` batch JSON as written by `wakeup-queue.sh` (see
`contracts/wakeup.md` for the field semantics `build_entry_json` draws
from). The batch's actual writer does not currently emit a `mentions` key;
this renderer treats `mentions` as optional (defaults to `[]`) so it renders
correctly today and the moment a future writer adds `mentions` per the
shape below, no renderer change is needed.

```json
{
  "schema_version": "1.0.0",
  "fired_at": "<iso timestamp>",
  "today": "YYYY-MM-DD",
  "budget": { "max": 3, "used_before": 0, "used_after": 2 },
  "entries": [
    {
      "id": "...",
      "due": "YYYY-MM-DD",
      "people": ["slug"],
      "why": "...",
      "origin": "signal|standing|user-ask",
      "kind": "nudge|event-proposal",
      "signal_type": "birthday|null",
      "context": "<text>",
      "draft": "<text or empty/null>",
      "proposed_event": null | { "title": "...", "start": "...", "end": "..." }
    }
  ],
  "held_budget": ["id"],
  "held_adjacent": ["id"],
  "mentions": [
    {
      "kind": "undebriefed-meeting",
      "event_id": "...",
      "summary": "...",
      "date": "...",
      "people": ["slug"],
      "line": "<text>"
    }
  ]
}
```

## Output

One plain-text message on stdout, no markdown tables, no HTML.

### Cards

One card per `entries[]` element, in array order, numbered `1.`, `2.`, …
Cards are separated by a blank line. Each card:

1. Line 1: `<n>. <why>`, with ` (<signal_type>)` appended when `signal_type`
   is non-null.
2. Line 2: the entry's `people`, rendered as `[[slug]]` links joined by
   `, `.
3. If `context` is non-empty: the context text as its own line(s).
4. If `draft` is non-empty: a line reading exactly `Draft (unsent):`
   followed by the draft's text (verbatim, may be multi-line).
5. If `kind` is `event-proposal`: a line `Proposed: <title> — <start> →
   <end>` (from `proposed_event`), then a line `Reply "<n> done" after you
   create it.`

### Mentions

After all cards (separated by a blank line from the last card), each
`mentions[].line` renders once, un-numbered, each separated from the next
by a blank line. Omitted entirely when `mentions` is absent or empty.

### Footer

The message's last line, verbatim:

```
Reply with the number: <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>
```

`<n>` is a literal placeholder token, not filled per-card — it names the
reply grammar once for the whole message.

### The no-guilt list (never rendered)

This renderer never surfaces: `budget`, `held_budget`, `held_adjacent`, the
words "pending", "missed", "overdue", any streak or backlog count, or batch
age. Capture and delivery are lossy-tolerant by design (see
`docs/PROJECT-CONTEXT.md` / CLAUDE.md standing principles) — nothing here
turns an unactioned nudge into a guilt signal.

## Exit codes

| Code | Condition |
|---|---|
| 0 | Rendered normally, message on stdout. |
| 2 | Input file missing, unreadable, or not valid JSON — a stderr line names the file/reason. |
| 3 | `entries` is empty (or absent) — no output, nothing to say. |

## Example

Given a batch with a `standing` birthday entry (no draft), a `signal`
job-change entry (with a draft), and an `event-proposal` entry, plus one
`mentions` item, the rendered message looks like:

```
1. birthday coming up (birthday)
[[dana-whitfield]]
Dana turns 34 on Sept 20.

2. job change: now leading partnerships at Meridian (job-change)
[[sam-okafor]]
Sam moved to Meridian as Head of Partnerships last month.
Draft (unsent):
Congrats on the new role at Meridian! Would love to catch up sometime.

3. quarterly catch-up is due
[[jordan-lee]]
It's been a while since you and Jordan connected in person.
Proposed: Coffee with Jordan — 2026-09-05T10:00:00-04:00 → 2026-09-05T10:30:00-04:00
Reply "3 done" after you create it.

You never debriefed "Weekly sync" with [[jordan-lee]] on 2026-08-28.

Reply with the number: <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>
```

## Notes

- Draft-never-send holds here too: `Draft (unsent):` is the only presentation
  of `draft` text — it is never sent on the renderer's own initiative, only
  handed to the human to copy, edit, or approve.
- This contract is read-only over its input; it has no store location of its
  own (it produces a transient message, not a persisted artifact).
</content>
