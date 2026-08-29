# Contract: capture event

`schema_version: 1.0.0`

## Store location

`inbox/<id>.md` — one file per capture event. Files are never edited after
creation; the inbox is an append-only archive (raw text kept forever, per
`docs/DECISIONS.md#gmail-first-capture` and the capture-is-lossy-tolerant
principle).

## Writer / readers

- **Sole writer:** connectors, input side (`packages/connectors/*-in`). This is
  an input connector's entire obligation — write a valid capture event into
  `inbox/`, nothing else.
- **Reader:** the filing engine (`packages/ingestion`), which turns capture
  events into `person`/`interaction` files and never mutates the capture
  event itself.

## Shape

Markdown file with YAML frontmatter (the envelope) followed by the raw
captured text (the body). Normalization is **envelope-only** — the body is
verbatim, untouched, forever. Connectors write the envelope; they never
rewrite, summarize, or interpret the body.

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `id` | string | yes | Unique within `inbox/`. Recommended form: `<captured_at-compact>-<source>-<short-rand>`, e.g. `20260829T143200Z-gmail-in-9f2a`. Also the filename stem (`inbox/<id>.md`). |
| `source` | string | yes | The writing connector's name, e.g. `gmail-in`, `calendar-in`, `contacts-in`, `manual`. |
| `captured_at` | ISO 8601 timestamp | yes | `YYYY-MM-DDTHH:MM:SSZ`. When the connector captured the item (not necessarily when the underlying event happened). |
| `type` | enum | yes | One of: `voice-note`, `linkedin-notification`, `event-confirmation`, `transcript`, `other`. |
| `participant-hints` | list of strings | no (default `[]`) | Raw, unresolved participant identifiers as seen in the source — names, emails, handles. The filing engine resolves these to `[[slug]]` person links; capture events never contain resolved links. |

### Body

Everything after the frontmatter's closing `---` is the raw captured text,
byte-for-byte as received from the source. No trimming, no reformatting, no
redaction.

## Example

`inbox/20260829T143200Z-gmail-in-9f2a.md`:

```markdown
---
schema_version: 1.0.0
id: 20260829T143200Z-gmail-in-9f2a
source: gmail-in
captured_at: 2026-08-29T14:32:00Z
type: voice-note
participant-hints:
  - "Dana Whitfield"
  - "dana.whitfield@example.com"
---
Subject: debrief: coffee with dana

ok so just grabbed coffee with dana whitfield, she's now leading the
fintech partnerships team at her company, sounded stressed about the
berlin move happening end of september, said she'd send me the deck
she's building once its done, need to follow up on that in like three
weeks
```

## Notes

- `type: other` is the escape hatch for capture sources not yet enumerated;
  widening the enum is a `schema_version` minor bump (additive), not a major
  one.
- Multiple capture events may reference the same underlying interaction
  (e.g. a calendar `event-confirmation` plus a later voice-note debrief) —
  reconciling them is the filing engine's job via `interaction.md`'s
  `source-capture` field, not the capture event's.
