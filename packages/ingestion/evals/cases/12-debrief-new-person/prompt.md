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
met). Do not run the optional research-seed pass (off by default, not
requested here). Do not run `build-index.sh` or `validate-store.sh` — this
eval only grades the `people/`/`interactions/`/`wakeups/` writes.

## The two files this pass writes — both brand new

This pass creates exactly two files: `people/priya-nair.md` (a new person)
and `interactions/2026-08-29-priya-nair.md` (the linked interaction). Both
must conform to the real store contracts below — do not invent field names
or section headings; these two schemas are the complete, exhaustive shape.

### `people/priya-nair.md` — person.md 1.0.0

Start from `packages/core/templates/person.md`. Its frontmatter has exactly
these possible keys (fill only what the debrief supports; omit the rest —
never invent a field like `company`, `context`, `context-details`, or
`status`, none of which exist in this contract):

| Field | Required | Value for this pass |
|---|---|---|
| `schema_version` | yes | `1.0.0` |
| `name` | yes | `Priya Nair` |
| `org` | no | `Lumen Analytics` |
| `role` | no | `Product Manager` |
| `location` | no | omit — not stated |
| `tags` | no | omit — not stated |
| `birthday` | no | omit — not stated |
| `how-met` | no | omit here (this pass records it in `## Personal details` instead — either placement is valid, never both) |
| `last-touch` | no | `2026-08-29` |
| `tier` | no | `active` — this is a judgment call SKILL.md explicitly makes for this exact case: the debrief's own enthusiasm and "want to keep in touch" framing earns a tier, it is not a blanket default for every new person |

Followed by exactly three body sections, in this order:

```
## Facts

- **[told-by-user]** Product Manager at Lumen Analytics (2026-08-29)
- **[told-by-user]** Hiring for a data engineering role (2026-08-29)

## Open threads

- Keep an eye out for data engineering candidates to refer to Priya.

## Personal details

**[told-by-user]** Met through the fintech founders Slack community.
```

Every fact bullet under `## Facts` and every factual claim under
`## Personal details` must carry the `**[told-by-user]**` provenance tag
with a trailing `(2026-08-29)` date — this is a human debrief, never
`**[inferred-public-web]**` (that tag is reserved for the off-by-default
research-seed pass, not run here).

### `interactions/2026-08-29-priya-nair.md` — interaction.md 1.0.0

Filename per SKILL.md section 5b's rule
(`<date>-<primary-person-slug>.md`), never the capture event's own `id`.
Frontmatter, per `packages/core/contracts/interaction.md` (complete field
list — do not add or omit any):

| Field | Value for this pass |
|---|---|
| `schema_version` | `1.0.0` |
| `date` | `2026-08-29` |
| `people` | `["[[priya-nair]]"]` |
| `calendar-event` | `null` |
| `source-capture` | `20260829T101500Z-manual-3a7c` |

Followed by exactly two body sections, in this order: `## Summary` (free
prose retelling what happened — Priya's role, org, how you met, that she's
hiring and asked for referrals, that it was a good first conversation) and
`## Commitments` (`_none_` — nobody in this debrief explicitly promised to
do anything; "want to keep in touch" is a sentiment, not a stated
commitment).
