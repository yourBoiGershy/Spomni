---
tier: skill
store: packages/ingestion/tests/goldens/debrief/05-two-word-minimal/before
expected: packages/ingestion/tests/goldens/debrief/05-two-word-minimal/expected
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
id: 20260829T151000Z-manual-2c9f
source: manual
captured_at: 2026-08-29T15:10:00Z
type: voice-note
participant-hints:
  - "Dana"
---
coffee, dana
```

Resolve "Dana" against `./store` (there is exactly one Dana on file). File
per SKILL.md sections 2-5: this is a bare two-word debrief with no new
fact — do not invent detail. `people/dana-kowalski.md` only gets its
`last-touch` advanced to `2026-08-29`; the new interaction file's
`## Commitments` is `_none_` and its `## Summary` is still written in full
prose despite the thin input. Do not run `build-index.sh` or
`validate-store.sh` — this eval only grades the
`people/`/`interactions/`/`wakeups/` writes.
