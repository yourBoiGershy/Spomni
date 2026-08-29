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

Resolve "Priya Kessler" against `./store`, then file per SKILL.md sections
2-5. This is a rambly, multi-topic debrief — every topic (the job move, the
half marathon, the dog's surgery, the brother's visit) must surface
somewhere in `./store` (facts, open threads, or personal details), none
silently dropped. Do not run `build-index.sh` or `validate-store.sh` — this
eval only grades the `people/`/`interactions/`/`wakeups/` writes.
