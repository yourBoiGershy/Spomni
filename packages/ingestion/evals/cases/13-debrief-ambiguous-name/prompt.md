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

Resolve "Sarah" against `./store`. If `participant-hints` resolves to more
than one person and the utterance gives too little context to pick one, do
NOT write anything — per SKILL.md section 4's one-question rule, ask exactly
one clarifying question naming the candidates by `[[slug]]` and a one-line
identifying fact each, instead of guessing. Do not create, edit, or touch any
file under `./store` while the question is outstanding — a declined or
unanswered ambiguous match leaves no trace in the store.
