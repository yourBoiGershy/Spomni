# Contract: interaction

`schema_version: 1.0.0`

## Store location

`interactions/<id>.md` — one file per filed touchpoint. `id` is also the
filename stem. Recommended form: `<date>-<primary-person-slug>[--<n>]`, e.g.
`2026-08-29-dana-whitfield.md` (append `--2` etc. for same-day duplicates).

## Writer / readers

- **Sole writer:** the filing engine (`packages/ingestion`), turning one or
  more capture events into a filed interaction.
- **Readers:** `packages/attention` (recency/signal input), `packages/query`
  (briefs, "what happened last time" answers), `build-index.sh` (derives a
  person's `last-touch`).

## Shape

Markdown file with YAML frontmatter plus two fixed prose sections.

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `date` | ISO 8601 date | yes | `YYYY-MM-DD`. The date the touchpoint happened (not the filing date). |
| `people` | list of `[[slug]]` links | yes (≥1) | Every person party to the interaction, e.g. `["[[dana-whitfield]]"]`. Multi-person interactions (group dinners, panels) list all of them. |
| `calendar-event` | string or `null` | no (default `null`) | Opaque link back to the source calendar event (e.g. its calendar event ID), when the interaction is tied to one. `null` for interactions with no calendar counterpart (a cold call, a chance encounter). |
| `source-capture` | string or `null` | yes | The `id` of the `inbox/` capture event this interaction was filed from (see `capture-event.md`). `null` only for interactions filed without a capture event (rare — e.g. manual backfill). |

### Body sections (fixed, in this order)

#### `## Summary`

Free prose: what happened, in the filing engine's structured retelling of
the debrief/capture — not a verbatim copy of the capture event's body.

#### `## Commitments`

A bullet list of commitments extracted from the interaction — promises made
by either side. Each bullet should read as `<owner>: <what> [by <date>]`
where `<owner>` is `user` or the relevant person's `[[slug]]`. Empty list
(`_none_`) is valid.

## Example

`interactions/2026-08-29-dana-whitfield.md`:

```markdown
---
schema_version: 1.0.0
date: 2026-08-29
people: ["[[dana-whitfield]]"]
calendar-event: null
source-capture: 20260829T143200Z-gmail-in-9f2a
---

## Summary

Grabbed coffee with Dana. She's now leading Meridian's fintech partnerships
team and is relocating to Berlin at the end of September — sounded a little
stressed about the move. She's building a partnerships deck and offered to
share it once it's done.

## Commitments

- [[dana-whitfield]]: send over the partnerships deck [by 2026-09-30]
- user: check in on how the Berlin move went [by 2026-10-15]
```

## Notes

- `people` uses the same `[[slug]]` link syntax as `person.md`'s
  cross-references — a validator can grep every `interactions/*.md` for
  `\[\[([a-z0-9-]+)\]\]` and confirm each resolves to a `people/<slug>.md`.
- An interaction with `source-capture: null` and no `calendar-event` is
  still valid (a manually-logged touchpoint) but should be rare enough that
  `validate-store.sh` may flag it as advisory, not an error.
