# Contract: nudge-card

`schema_version: 1.1.0`

## Purpose

Turns one fired wake-up batch (`packages/attention/scripts/wakeup-queue.sh
fire`'s batch artifact, `wakeups/fired/<today>T<HHMMSS>Z-batch.json`) into a
single plain-text chat message: numbered cards the human can reply to
inline. This is the last mile of `wakeup-queue-over-digests` — the queue
decides *what* and *when*; this contract decides how it reads as one message
a human can act on without opening a UI. Mission test: the card is the push
to reach out — a concrete next action motivates, never guilt; it never
substitutes for the human's own words, so the card itself carries no draft
text. A draft is served only on request (`<n> draft`, plan 34 U8b), keeping
the human as the one who writes and sends.

**1.1.0 (plan 33 D3/D4 amendment, "nudge first, draft on demand"):** cards
are two lines max, capped at 5 per message, and never carry `context` or
`draft` inline — line 2 is a deterministic next action derived from the
entry, not the free-text draft. See "Cards" below for the full rule.

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

`entries[].people` entries may be bare slugs (`"aaron"`) or already
wrapped (`"[[aaron]]"`) — the live writer passes the wakeup frontmatter
`people` value straight through, which is already bracketed. The renderer
strips any leading `[[` / trailing `]]` before wrapping, so each person is
rendered exactly once as `[[slug]]` regardless of which form the input
uses.

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
**Cards are capped at 5 per message: only the first 5 `entries[]` elements
render; anything beyond the 5th is silently not rendered — the card never
mentions how many were cut (no-guilt: batch size/backlog is never
surfaced).** Cards are separated by a blank line. Each card is **exactly
two lines**:

1. Line 1: `<n>. <people as [[slug]] joined by ", "> — <why>`, with `
   (<signal_type>)` appended when `signal_type` is non-null. `people` is
   rendered as `[[slug]]` links joined by `, ` (bare or already-bracketed
   input slugs both normalize to a single `[[slug]]`, as before).
2. Line 2: `→ <one concrete action>`, deterministically derived from the
   entry (never the free-text `draft`):
   - `proposed_event` present (non-null): `→ create "<title>" <start> and
     reply "<n> done"`.
   - else by `signal_type`:
     - `birthday` → `→ send a birthday note today`
     - `job-change` → `→ congratulate them on the new role`
     - `scheduling-intent` → `→ propose a time this week`
     - `co-attendance` → `→ follow up on what you discussed`
     - `company-news` → `→ send a note about the news`
     - `tier-drift` → `→ reach out this week — it's been a while`
     - `linkedin-post` → `→ react to their post with a line`
   - else if `origin` is `user-ask` → `→ do what you asked yourself to do`.
   - else (no `signal_type` match, no `proposed_event`, `origin` not
     `user-ask`) → `→ reach out this week`.

`context` and `draft` are **never rendered in the card** — `context` is
ammunition kept for the on-demand draft, and `draft` is served only when the
human replies `<n> draft` (plan 34 U8b), not printed inline here.

### Mentions

After all cards (separated by a blank line from the last card), each
`mentions[].line` renders once, un-numbered, each separated from the next
by a blank line. Omitted entirely when `mentions` is absent or empty.

### Footer

The message's last line, verbatim:

```
Reply: <n> draft | <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>
```

`<n>` is a literal placeholder token, not filled per-card — it names the
reply grammar once for the whole message. `<n> draft` is new in 1.1.0 —
serves the entry's `draft` text (headed `Draft (unsent):`) as a follow-up
message, per plan 34 U8b; it is never printed inline in the card itself.

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

Given a batch with a `standing` birthday entry, a `signal` job-change entry,
and an `event-proposal` entry, plus one `mentions` item, the rendered
message looks like:

```
1. [[dana-whitfield]] — birthday coming up (birthday)
→ send a birthday note today

2. [[sam-okafor]] — job change: now leading partnerships at Meridian (job-change)
→ congratulate them on the new role

3. [[jordan-lee]] — quarterly catch-up is due
→ create "Coffee with Jordan" 2026-09-05T10:00:00-04:00 and reply "3 done"

You never debriefed "Weekly sync" with [[jordan-lee]] on 2026-08-28.

Reply: <n> draft | <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>
```

## Notes

- Draft-never-send holds here too: `Draft (unsent):` is the only presentation
  of `draft` text, and even that only appears when the human explicitly
  replies `<n> draft` (plan 34 U8b) — it is never sent on the renderer's own
  initiative, only handed to the human to copy, edit, or approve.
- This contract is read-only over its input; it has no store location of its
  own (it produces a transient message, not a persisted artifact).
- The two-line card and deterministic action line exist so the card itself
  is the push to reach out — a concrete next action motivates without
  guilt — while the draft stays one reply away rather than crowding the
  card the human is meant to act on.
</content>
