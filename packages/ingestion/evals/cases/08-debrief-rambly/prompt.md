---
tier: skill
store: packages/ingestion/tests/goldens/debrief/02-rambly-multi-topic/before
expected: packages/ingestion/tests/goldens/debrief/02-rambly-multi-topic/expected
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
id: 20260829T183000Z-manual-4d02
source: manual
captured_at: 2026-08-29T18:30:00Z
type: voice-note
participant-hints:
  - "Priya Kessler"
---
Okay so, phone call with Priya Kessler this afternoon, went kind of long. So
first she was telling me about work — she's moving from the design team
over to a new "platform experience" group at Northwind Labs, starts in two
weeks, she seems nervous about it honestly, said the scope is a lot bigger
than what she's used to. Then we got sidetracked talking about her half
marathon training, she's doing the Chicago one in October, first one ever,
she's a little worried about the long runs. Oh and her dog Biscuit had knee
surgery last week, recovering fine now but it was a whole thing, she was
pretty stressed about the vet bills. Also she mentioned in passing that her
brother is visiting from Portland next month but we didn't get into details
on that. Anyway she said she'd send me the race date once registration
closes so I can maybe come cheer her on.
```

Resolve "Priya Kessler" against `./store` (there is exactly one matching
person file, `people/priya-kessler.md`).

You MUST create exactly one new file, `interactions/2026-08-29-priya-kessler.md`
— this is not optional narration, it is a file write. Its shape is fixed by
`packages/core/contracts/interaction.md` (schema_version 1.0.0). Quoting the
contract's frontmatter table verbatim:

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | `1.0.0` |
| `date` | yes | `YYYY-MM-DD` — the touchpoint's date, `2026-08-29` here. |
| `people` | yes (≥1) | List of `[[slug]]` links, e.g. `["[[priya-kessler]]"]`. |
| `calendar-event` | no | `null` here — no linked calendar event. |
| `source-capture` | yes | The triggering capture event's `id`: `20260829T183000Z-manual-4d02`. |

Followed by two fixed prose sections, `## Summary` (free prose retelling of
what happened — never a verbatim copy of the capture body; this is a rambly,
multi-topic debrief, so the summary must surface every topic: the job move,
the half marathon, the dog's surgery, and the brother's visit) and
`## Commitments` (a bullet per promise surfaced, `<owner>: <what> [by <date>]`;
when no date is stated or implied, append `(no date given)` as plain trailing
prose instead of a bracketed `[by ...]` clause). The filename is
`interactions/<date>-<primary-person-slug>.md` —
`interactions/2026-08-29-priya-kessler.md` for this event.

Also apply the person-file update rules from SKILL.md §5a to
`people/priya-kessler.md` — every topic must land *somewhere* on this file
(facts, open threads, or personal details), none silently dropped:

- Every new factual claim surfaced by the debrief becomes a new bullet
  appended to `## Facts`, tagged `**[told-by-user]**` with a trailing capture
  date in parens, `(YYYY-MM-DD)`. Never delete or rewrite an existing
  `## Facts` bullet.
- `last-touch` is always set to the interaction's date (`2026-08-29`).
- A promise or loose end ("ask about X next time", "check in once she's
  settled") becomes a new bullet under `## Open threads` — no provenance tag
  needed.
- Texture that doesn't belong in the terse `## Facts` list (family, hobbies,
  how-they-met context — here: the dog's surgery, the marathon training)
  goes under `## Personal details`, tagged `**[told-by-user]**` wherever it
  states a fact; connective prose does not need a tag.

**Wake-up rule — read carefully, this case turns on it.** Per SKILL.md's
"Reminder-ask → wake-up entry" section, quoted verbatim: "Look for a
first-person imperative specifically asking to be reminded or followed up
with later — 'remind me to...', 'make sure I follow up...', 'don't let me
forget to...' ... This is distinct from implicit musing that merely notes a
future intention without asking for a nudge — 'I should really follow up
with him sometime', 'we should catch up again soon'. Musing like this
creates **no** wake-up; at most it earns an ordinary `## Open threads`
bullet on the person file per §5a, same as any other loose end, and nothing
more." Nothing in this debrief is a first-person imperative reminder-ask —
Priya saying she'll send a race date, the brother's visit, the marathon
worry, the surgery recovery are all topics/promises, not the user asking to
be reminded. Do **not** invoke `wakeup-add.sh` and do **not** create any
file under `wakeups/` for this event — every topic here resolves to a
`## Facts`, `## Open threads`, or `## Personal details` bullet only, never a
wake-up.

Do not run `build-index.sh` or `validate-store.sh` — this eval only grades
the `people/`/`interactions/`/`wakeups/` writes. Write the files now; do not
just describe what you would write.
