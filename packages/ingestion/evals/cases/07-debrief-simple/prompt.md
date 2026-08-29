---
tier: skill
store: packages/ingestion/tests/goldens/debrief/01-simple-single-person/before
expected: packages/ingestion/tests/goldens/debrief/01-simple-single-person/expected
max-turns: 8
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`. The current people-store is the
directory `./store` (contains `people/`, `interactions/`, `wakeups/`) — treat
it as the live store for this pass. This eval skips the `inbox/`/dedup-ledger
mechanics (no `data/ingestion/debrief-filed.log` bookkeeping needed here) —
just file the capture event below into `./store` exactly as single-event
mode would.

The capture event:

```
---
schema_version: 1.2.0
id: 20260829T093000Z-manual-b7e1
source: manual
captured_at: 2026-08-29T09:30:00Z
type: voice-note
participant-hints:
  - "Jordan Ellery"
---
Grabbed lunch with Jordan Ellery today. He just got promoted to Head of
Production at Anchor Studios, sounds really excited about it. Said he's been
meaning to introduce me to their marketing lead at some point, nothing
urgent though. Good catch-up overall, nothing else major to report.
```

Resolve "Jordan Ellery" against `./store` (there is exactly one matching
person file, `people/jordan-ellery.md`).

You MUST create exactly one new file, `interactions/2026-08-29-jordan-ellery.md`
— this is not optional narration, it is a file write. Its shape is fixed by
`packages/core/contracts/interaction.md` (schema_version 1.0.0). Quoting the
contract's frontmatter table verbatim:

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | `1.0.0` |
| `date` | yes | `YYYY-MM-DD` — the touchpoint's date, `2026-08-29` here. |
| `people` | yes (≥1) | List of `[[slug]]` links, e.g. `["[[jordan-ellery]]"]`. |
| `calendar-event` | no | `null` here — no linked calendar event. |
| `source-capture` | yes | The triggering capture event's `id`: `20260829T093000Z-manual-b7e1`. |

Followed by two fixed prose sections, `## Summary` (free prose retelling of
what happened — never a verbatim copy of the capture body) and
`## Commitments` (a bullet per promise surfaced, `<owner>: <what> [by <date>]`;
when no date is stated or implied, append `(no date given)` as plain trailing
prose instead of a bracketed `[by ...]` clause; `_none_` if there are none).
The filename is `interactions/<date>-<primary-person-slug>.md` —
`interactions/2026-08-29-jordan-ellery.md` for this event.

On what counts as a commitment, quoting SKILL.md verbatim: "Any explicit
promise or clearly stated intention by either party to do something,
surfaced anywhere in the debrief — not only crisp 'I'll do X' lines. A
soft, no-rush framing still counts: ... 'Said he's been meaning to
introduce me to their marketing lead at some point, nothing urgent though'
is a real stated intention from Jordan and gets a bullet, even though
nothing about it is urgent or scheduled." That is exactly the shape of the
sentence in this capture event — Jordan's mentioned intro is a real
commitment and belongs under `## Commitments` as
`[[jordan-ellery]]: introduce the user to Anchor Studios' marketing lead
(no date given)`, never `_none_`.

Also apply the person-file update rules from SKILL.md §5a to
`people/jordan-ellery.md`:

- Every new factual claim surfaced by the debrief becomes a new bullet
  appended to `## Facts`, tagged `**[told-by-user]**` with a trailing capture
  date in parens, `(YYYY-MM-DD)`. Never delete or rewrite an existing
  `## Facts` bullet, even when a new fact supersedes it.
- When a new fact changes a field `person.md` tracks in frontmatter (here:
  `role`, since Jordan was promoted), update that frontmatter field to the
  new value — frontmatter is current-state, not a journal.
- `last-touch` is always set to the interaction's date (`2026-08-29`),
  regardless of what else changed.
- A promise or loose end ("ask about X next time") becomes a new bullet
  under `## Open threads` on the person file — no provenance tag needed.

Do not run `build-index.sh` or `validate-store.sh` — this eval only grades
the `people/`/`interactions/`/`wakeups/` writes. Write the files now; do not
just describe what you would write.
