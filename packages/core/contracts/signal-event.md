# Contract: signal event

`schema_version: 1.0.0`

## Store location

`wakeups/signals/<id>.md` — one file per detected signal. This is a
subdirectory of `wakeups/` (see `docs/PROJECT-CONTEXT.md`'s store shape): a
signal event is a *proposal* to reach out, not yet a nudge. It becomes a
nudge only when `packages/attention` promotes it into a `wakeup.md` entry
with `origin: signal` — at which point the wake-up's `## Context` section
references the signal file by id. Signal events are an append-only log; they
are never deleted, only superseded by the wake-up (or lack thereof) they
produce.

## Writer / readers

- **Sole writer:** `packages/attention` (the signal engine).
- **Readers:** `packages/attention` itself (ranking, dedup against
  already-fired signals), `packages/query` (explaining "why is this nudge
  here").

## Shape

Markdown file with YAML frontmatter only; no fixed body sections (evidence
lives in the frontmatter as it's typically short and structured).

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `id` | string | yes | Unique within `wakeups/signals/`. Recommended form: `<detected_at-compact>-<type>-<person-slug>`, e.g. `20260829T090000Z-job-change-dana-whitfield`. Also the filename stem. |
| `type` | string | yes | The detector that fired, e.g. `birthday`, `job-change`, `company-news`, `co-attendance`, `linkedin-post`. Open vocabulary — new detectors add new types without a schema bump. |
| `person` | list of `[[slug]]` links | yes (≥1) | The person(s) the signal is about. A list to cover co-attendance (two people showing up at the same event). |
| `evidence` | string | yes | Free text: what was observed and where — e.g. a quoted line from a notification email, a news headline + URL, the calendar event that co-attendance was drawn from. Should be self-sufficient for a human to judge the signal without re-fetching the source. |
| `confidence` | enum | yes | One of: `low`, `medium`, `high`. Feeds ranking (`docs/PROJECT-CONTEXT.md`: "two independent signals for high priority"). |
| `detected_at` | ISO 8601 timestamp | yes | `YYYY-MM-DDTHH:MM:SSZ`. When the signal engine detected it (not when the underlying event happened). |

## Example

`wakeups/signals/20260829T090000Z-job-change-dana-whitfield.md`:

```markdown
---
schema_version: 1.0.0
id: 20260829T090000Z-job-change-dana-whitfield
type: job-change
person: ["[[dana-whitfield]]"]
evidence: >
  LinkedIn notification email received 2026-08-28: "Dana Whitfield started
  a new position as Head of Partnerships at Meridian Fintech." Corroborated
  by email signature diff on 2026-08-25 (title changed from "Senior
  Partnerships Manager").
confidence: high
detected_at: 2026-08-29T09:00:00Z
---
```

## Notes

- `confidence: high` typically means two independent pieces of evidence
  corroborate the same signal (per the ranking heuristic in
  `docs/PROJECT-CONTEXT.md`); a single weak source (e.g. a "ring the bell"
  LinkedIn post notification with no other corroboration) is `low` or
  `medium`.
- Not every signal event produces a wake-up — attention may dedup, suppress,
  or hold a low-confidence signal pending corroboration. The signal log
  persists regardless, so ranking/dedup logic has history to work against.
