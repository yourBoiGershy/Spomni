---
tier: skill
store: packages/ingestion/tests/goldens/debrief/10-contradicts-existing-fact/before
expected: packages/ingestion/tests/goldens/debrief/10-contradicts-existing-fact/expected
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
id: 20260829T170000Z-manual-d40a
source: manual
captured_at: 2026-08-29T17:00:00Z
type: voice-note
participant-hints:
  - "Sofia Alvarez"
---
Caught up with Sofia — big news, she left Acme Corp last month and just
started as VP of Sales at Globex Corp. Sounds like a great move for her.
```

Resolve "Sofia Alvarez" against `./store` — her `people/sofia-alvarez.md`
currently has `org: Acme Corp`. File per SKILL.md section 5a's frontmatter-
vs-facts split: update the frontmatter `org`/`role` fields to the new
company/title (Globex Corp, VP of Sales) — frontmatter is current-state —
but **never delete or rewrite** the existing `## Facts` bullet recording the
old `Sales Director at Acme Corp` fact; append the new fact as a new, dated
bullet below it instead. `## Facts` is an append-only, dated journal, not a
mutable snapshot. Do not run `build-index.sh` or `validate-store.sh` — this
eval only grades the `people/`/`interactions/`/`wakeups/` writes.
