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

Resolve "Jordan Ellery" against `./store`, then file per SKILL.md sections
2-5: person fact/frontmatter updates, `last-touch`, open threads, and the
new `interactions/2026-08-29-jordan-ellery.md` file with summary and
commitments. Do not run `build-index.sh` or `validate-store.sh` — this eval
only grades the `people/`/`interactions/`/`wakeups/` writes.
