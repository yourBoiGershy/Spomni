---
tier: skill
store: packages/ingestion/tests/goldens/debrief/06-new-unknown-person/before
expected: packages/ingestion/tests/goldens/debrief/06-new-unknown-person/expected
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
id: 20260829T101500Z-manual-3a7c
source: manual
captured_at: 2026-08-29T10:15:00Z
type: voice-note
participant-hints:
  - "Priya Nair"
---
Just had a great intro call with Priya Nair, she's a Product Manager at
Lumen Analytics, we met through the fintech founders Slack. She mentioned
she's hiring for a data engineering role and asked if I knew anyone. Good
chat, want to keep in touch.
```

"Priya Nair" has no match in `./store` — this is the "New-person creation"
extension in SKILL.md's "Not in this core" section. She clears the bar for
creating a person file (a real, individual person with substance, freshly
met). Create `people/priya-nair.md` from `packages/core/templates/person.md`
with every seeded fact tagged `**[told-by-user]**` and dated `(2026-08-29)`,
`last-touch: 2026-08-29`, and file the linked
`interactions/2026-08-29-priya-nair.md` per SKILL.md section 5b. Do not run
the optional research-seed pass (off by default, not requested here). Do not
run `build-index.sh` or `validate-store.sh` — this eval only grades the
`people/`/`interactions/`/`wakeups/` writes.
