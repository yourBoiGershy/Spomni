# Contract: person

`schema_version: 1.0.0`

## Store location

`people/<slug>.md` — one file per person. `slug` is the person's filename
stem, kebab-case, derived from `name` (e.g. "Dana Whitfield" → `dana-whitfield`).
The slug is how every other artifact links to this person via `[[slug]]`
wiki-links (see `docs/PROJECT-CONTEXT.md`'s store shape).

## Writer / readers

- **Sole writer:** the filing engine (`packages/ingestion`) — creates and
  updates person files from capture events and debriefs.
- **Readers:** `packages/attention` (signal detection, wake-up context),
  `packages/query` (answers, briefs), `packages/core/scripts/build-index.sh`.

## Shape

Markdown file with YAML frontmatter plus three fixed prose sections.

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `name` | string | yes | Full display name. |
| `org` | string | no | Current organization. Omit (or leave empty) if unknown — never invent. |
| `role` | string | no | Current title/role. |
| `location` | string | no | City or region, freeform. |
| `tags` | list of strings | no (default `[]`) | Freeform categorization, e.g. `[fintech, college-friend]`. Drives `index.json` and query filtering. |
| `birthday` | ISO 8601 date | no | `YYYY-MM-DD` if the year is known; `--MM-DD` (ISO 8601 reduced form, year omitted) if only month/day is known. |
| `how-met` | string | no | One line of context on how the user knows this person. |
| `last-touch` | ISO 8601 date | no | `YYYY-MM-DD`. Auto-maintained by the filing engine as the most recent linked `interaction.md` date — never hand-edited. |
| `tier` | enum | no | One of: `inner-circle`, `close`, `active`, `dormant`. Relationship-warmth bucket; feeds nudge ranking (`docs/PROJECT-CONTEXT.md`'s warmth × rarity ranking). |

### Body sections (fixed, in this order)

#### `## Facts`

A bullet list. **Every fact carries a provenance tag** — the binding rule
from `docs/DECISIONS.md#provenance-labeling`: told-by-user vs.
inferred-from-public-web, never mixed or defaulted. Tag format, at the start
of the bullet:

```
- **[told-by-user]** <fact text>
- **[inferred-public-web]** <fact text>
```

Both tags may carry an optional trailing date in parens, `(2026-08-29)`,
noting when the fact was captured/inferred — useful for staleness checks.
Facts with no tag are a validator error (see `validate-store.sh`).

#### `## Open threads`

A bullet list of things to follow up on next time — questions asked, topics
promised, loose ends. No provenance tag required (these are prospective, not
factual claims).

#### `## Personal details`

Free prose (or bullets) for texture that doesn't fit the terse `Facts` list —
family, hobbies, preferences. Apply the same `**[told-by-user]**` /
`**[inferred-public-web]**` tagging convention wherever a claim of fact is
made; pure connective prose does not need a tag.

## Example

`people/dana-whitfield.md`:

```markdown
---
schema_version: 1.0.0
name: Dana Whitfield
org: Meridian Fintech
role: Head of Partnerships
location: Berlin, Germany
tags: [fintech, college-friend]
birthday: --03-14
how-met: Sophomore year, same dorm floor at Michigan
last-touch: 2026-08-29
tier: close
---

## Facts

- **[told-by-user]** Now leading the fintech partnerships team (2026-08-29)
- **[told-by-user]** Moving to Berlin end of September for work (2026-08-29)
- **[inferred-public-web]** Meridian Fintech raised a Series C in June 2026 (2026-08-15)

## Open threads

- Said she'd send over the partnerships deck once it's done — follow up
  mid-September if it hasn't arrived.
- Ask how the Berlin move went once she's settled.

## Personal details

Runs marathons; ran Berlin in 2024 which is part of why she picked the
relocation. **[told-by-user]** Has a younger brother who also lives in
Berlin.
```

## Notes

- `org`/`role`/`location`/`tags` are exactly the fields `build-index.sh`
  projects into `index.json`, alongside `last-touch` — keep names identical
  or the index generator and this contract drift.
- A person with no `org` (freelancer, personal contact) is valid; omit the
  key rather than writing an empty string.
