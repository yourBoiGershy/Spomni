---
tier: skill
store: packages/ingestion/tests/goldens/debrief/08-commitment-by-user/before
expected: packages/ingestion/tests/goldens/debrief/08-commitment-by-user/expected
max-turns: 8
model: haiku
---
Act as ingestion's debrief filing skill (`packages/ingestion/skills/debrief/
SKILL.md`), filing exactly one capture event into the store at `./store`
(contains `people/`, `wakeups/` — `interactions/` does not exist yet, create
it). Resolution is already done for you: the event's one participant hint,
"Marcus Webb", matches the existing `./store/people/marcus-webb.md` — no
ambiguity, no new person file. Skip `inbox/`/dedup-ledger bookkeeping (no
`data/ingestion/debrief-filed.log` write) and skip §5c's `build-index.sh`/
`validate-store.sh` calls — this eval only grades the `people/`/
`interactions/`/`wakeups/` writes themselves.

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

Two writes only, per the two contract excerpts below. Follow both to the
letter — do not improvise on the filename or the frontmatter shape.

**1. `people/marcus-webb.md`.** The debrief states nothing new about Marcus
himself (no new fact, no frontmatter-tracked field changed) — per SKILL.md
§5a, that means the *only* change to this file is `last-touch: 2026-08-29`
(the interaction's date, from the event's `captured_at`). Leave every other
field and section (`## Facts`, `## Open threads`, `## Personal details`)
byte-for-byte as they already are in `./store/people/marcus-webb.md`.

**2. `interactions/<id>.md` — new file.** Per SKILL.md §5b, the filename/id
is `<date>-<primary-person-slug>.md`: `<date>` is the interaction's date
(`2026-08-29`), `<primary-person-slug>` is the first (only, here) matched
person's slug (`marcus-webb`) — **not** any descriptive suffix like a topic
or activity word. Worked example of the rule (a different case, same
shape): a lunch debrief with `[[dana-whitfield]]` on `2026-08-29` files as
`interactions/2026-08-29-dana-whitfield.md`, never
`2026-08-29-dana-whitfield-lunch.md`. So this event files as exactly
`interactions/2026-08-29-marcus-webb.md`.

The file's frontmatter (`interaction.md` contract, `schema_version: 1.0.0`):

```
---
schema_version: 1.0.0
date: 2026-08-29
people: ["[[marcus-webb]]"]
calendar-event: null
source-capture: 20260829T150000Z-manual-6e2f
---
```

Body: a `## Summary` section in your own prose (never a verbatim copy of
the capture body) retelling the lunch and the portfolio-strategy
conversation, then a `## Commitments` section. Per SKILL.md's "Commitment
extraction (detail)" section: attribution is `user:` when the user is the
one who said they'd do something — here, the user explicitly said "I said
I'd send him the pitch deck..." — so the bullet is owned by `user`, not by
`[[marcus-webb]]`. The debrief names an explicit calendar date inside
relative phrasing ("by next Friday, September 4th") — per the date-capture
rule, use that stated date directly: `[by 2026-09-04]`. The bullet:

```
## Commitments

- user: send Marcus the pitch deck [by 2026-09-04]
```

Do not create, delete, or modify any file other than
`people/marcus-webb.md` (as scoped above) and the one new
`interactions/2026-08-29-marcus-webb.md` file. Do not touch `wakeups/`.
