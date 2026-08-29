---
tier: skill
store: packages/ingestion/tests/goldens/debrief/07-ambiguous-name/before
expected: packages/ingestion/tests/goldens/debrief/07-ambiguous-name/expected
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
id: 20260829T113000Z-manual-a1d4
source: manual
captured_at: 2026-08-29T11:30:00Z
type: voice-note
participant-hints:
  - "Sarah"
---
Grabbed coffee with Sarah today, she said the new job is going really well
and she's already leading a small team. Good catch-up, should do it again
soon.
```

`./store/people/` contains two candidates: `sarah-chen.md` (Sarah Chen,
Senior Consultant at Bright Path Consulting) and `sarah-park.md` (Sarah
Park, Engineering Manager at Vantage Robotics, recently started that role).
The hint `"Sarah"` matches both by first name (SKILL.md §3's known-alias
match). Neither the event nor the store gives disambiguating context (no
`chatID`/`title`, no co-participant hint, no calendar link tying it to one
candidate) — the "new job going well, leading a small team" detail is
consistent with either. This is SKILL.md §3's **Ambiguous** outcome:

> **Ambiguous** — a hint matches more than one person and context (step 3)
> cannot narrow it to one. Go to §4 instead of filing.

SKILL.md §4 (the one-question rule) is binding here, quoted verbatim:

> When an ambiguity is confirmed (per §3 step 3, unresolved by context):
>
> 1. Make **no store writes at all** — not to any candidate's `people/
>    <slug>.md`, not an interaction, nothing. The event's `inbox/` file is
>    untouched (it always is) and is **not** added to `data/ingestion/
>    debrief-filed.log` — it stays eligible for a future filing pass once
>    the ambiguity is resolved (e.g. the user answers, or a later event adds
>    disambiguating context).
> 2. Ask exactly one question, naming the candidates by their `[[slug]]` and
>    a one-line identifying fact each (org/role is usually enough), e.g.:
>    `"Which Sarah do you mean — Sarah Chen or Sarah Park?"`
> [...]
> 4. If the user never answers or declines to clarify, the fact is dropped
>    silently — never re-asked, never guessed (no-guilt principle; this
>    event simply never gets an entry in the filed ledger).
>
> This is the **only** branch where filing an event produces zero writes.
> Every other branch below always produces at least an interaction file.

Follow this rule for exactly this one event, then stop: do NOT write, edit,
or touch any file under `./store` — ask exactly one clarifying question that
names both candidates by `[[slug]]` (`[[sarah-chen]]` and `[[sarah-park]]`)
with a one-line identifying fact each (their org/role is enough), instead of
guessing or filing against either one.
