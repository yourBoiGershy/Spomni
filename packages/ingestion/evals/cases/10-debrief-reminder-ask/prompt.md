---
tier: skill
store: packages/ingestion/tests/goldens/debrief/04-embedded-reminder-ask/before
expected: packages/ingestion/tests/goldens/debrief/04-embedded-reminder-ask/expected
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
id: 20260829T113000Z-manual-6f28
source: manual
captured_at: 2026-08-29T11:30:00Z
type: voice-note
participant-hints:
  - "Marcus Yeun"
---
Quick coffee with Marcus Yeun. He's completely swamped this week putting
together a big client pitch, sounded pretty stressed about it. Didn't get
into much else. Remind me to follow up with him in three weeks, once the
pitch dust has settled.
```

Resolve "Marcus Yeun" against `./store`, then file per SKILL.md sections
2-5 and the "Reminder-ask → wake-up entry" section: this is an explicit
first-person reminder ask, not idle musing, so it produces a `## Commitments`
bullet owned by `user` due `[by 2026-09-19]` (three weeks from the
2026-08-29 interaction date) AND exactly one wake-up entry created via
`bash packages/core/scripts/wakeup-add.sh ./store --due 2026-09-19 --person
marcus-yeun ...` (never a hand-written `wakeups/*.md` file), plus an
`## Open threads` bullet on Marcus's person file pointing at the new
wake-up. Do not run `build-index.sh` or `validate-store.sh` — this eval only
grades the `people/`/`interactions/`/`wakeups/` writes.
