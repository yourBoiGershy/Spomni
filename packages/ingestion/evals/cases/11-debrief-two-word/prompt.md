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

## The interaction file you must write — exact shape (interaction.md 1.0.0)

The one new file this pass creates is `interactions/<id>.md`, where `<id>`
is **also the filename** — never the capture event's own `id`. Per
SKILL.md section 5b, the filename rule is:

```
<date>-<primary-person-slug>.md
```

`<date>` is the interaction's date (`2026-08-29`, from the capture event's
`captured_at`, truncated to `YYYY-MM-DD`); `<primary-person-slug>` is the
resolved person's slug (`dana-kowalski`). For this capture event, worked out,
the filename is exactly:

```
interactions/2026-08-29-dana-kowalski.md
```

Do **not** name the file after the capture event's `id`
(`20260829T151000Z-manual-2c9f`) — that id only appears inside the file, as
the `source-capture` frontmatter value below, never as the filename.

The file's frontmatter fields, per `packages/core/contracts/interaction.md`
(this is the complete field list — do not add or omit any):

| Field | Value for this pass |
|---|---|
| `schema_version` | `1.0.0` |
| `date` | `2026-08-29` |
| `people` | `["[[dana-kowalski]]"]` |
| `calendar-event` | `null` |
| `source-capture` | `20260829T151000Z-manual-2c9f` |

Followed by exactly two body sections, in this order: `## Summary` (full
prose, even for this thin input) and `## Commitments` (`_none_`, since
nothing was promised).

## The person file update — exact shape (person.md 1.0.0)

`people/dana-kowalski.md` already exists and conforms to
`packages/core/contracts/person.md`. This pass makes exactly one change to
it: advance `last-touch` to `2026-08-29` in the frontmatter. Leave every
other frontmatter field (`name`, `org`, `role`, `tags`, `tier`, etc.) and
every body section (`## Facts`, `## Open threads`, `## Personal details`)
byte-for-byte unchanged — this debrief states no new fact, so nothing is
appended or invented.
