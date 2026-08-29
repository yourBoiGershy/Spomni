---
tier: skill
store: packages/ingestion/tests/goldens/debrief/08-commitment-by-user/before
expected: packages/ingestion/tests/goldens/debrief/08-commitment-by-user/expected
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
id: 20260829T150000Z-manual-6e2f
source: manual
captured_at: 2026-08-29T15:00:00Z
type: voice-note
participant-hints:
  - "Marcus Webb"
---
Had lunch with Marcus Webb, good conversation about the fund's new
portfolio strategy. I said I'd send him the pitch deck we talked about by
next Friday, September 4th.
```

Resolve "Marcus Webb" against `./store`, then file per SKILL.md sections 2-5
and the "Commitment extraction (detail)" section: the user is the one who
committed here ("I said I'd send him..."), so the interaction's
`## Commitments` bullet is owned by `user`, reads `send Marcus the pitch
deck`, with the explicit stated date `[by 2026-09-04]`.
`people/marcus-webb.md` only advances `last-touch` — no new fact/frontmatter
change is stated about Marcus himself. Do not run `build-index.sh` or
`validate-store.sh` — this eval only grades the
`people/`/`interactions/`/`wakeups/` writes.
