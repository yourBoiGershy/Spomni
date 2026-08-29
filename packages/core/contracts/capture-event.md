# Contract: capture event

`schema_version: 1.2.0`

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
| `source` | string | yes | The writing connector's name. Convention for multi-lane connectors: `<connector>/<lane>`, e.g. `composio-in/gmail`, `composio-in/googlecalendar`, `composio-in/linkedin` — the connector half is the writing sub-package, the lane half is the Composio toolkit slug. Chat lanes follow the same form, e.g. `beeper-in/whatsapp`. Plain connector names (`manual`, `gmail-in`) remain valid; `source` is a free string, not an enum. |
| `captured_at` | ISO 8601 timestamp | yes | `YYYY-MM-DDTHH:MM:SSZ`. When the connector captured the item (not necessarily when the underlying event happened). The `id` and filename derive from this, keeping `inbox/` chronological by capture. |
| `type` | enum | yes | One of: `voice-note`, `linkedin-notification`, `event-confirmation`, `transcript`, `other`, `email`, `calendar-event`, `profile-snapshot`, `contact-record`, `post`, `chat-message`. `event-confirmation` is a confirmation *email*; `calendar-event` is the event record itself; `chat-message` is a message in a chat/DM conversation — WhatsApp, iMessage, Signal, Telegram, Discord DM, etc. — as distinct from `email`. `other` is the escape hatch for genuinely unclassifiable items, not a default. |
| `occurred_at` | ISO 8601 timestamp | no | `YYYY-MM-DDTHH:MM:SSZ`. When the underlying thing happened or will happen — a calendar event's start, an email's `Date` header, a post's publish time. Distinct from `captured_at` (when the sweep ran); omit when the source has no inherent occurrence time. |
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

A second example, a calendar event captured through a Composio lane, showing
`occurred_at` and the `<connector>/<lane>` `source` form:

`inbox/20260907T090000Z-composio-in-googlecalendar-7c1e.md`:

```markdown
---
schema_version: 1.1.0
id: 20260907T090000Z-composio-in-googlecalendar-7c1e
source: composio-in/googlecalendar
captured_at: 2026-09-07T09:00:00Z
occurred_at: 2026-09-10T15:00:00Z
type: calendar-event
participant-hints:
  - "Dana Whitfield <dana.whitfield@example.com>"
  - "Priya Nair <priya.nair@example.com>"
---
{
  "summary": "Fintech partnerships sync",
  "start": { "dateTime": "2026-09-10T15:00:00Z" },
  "attendees": [
    { "email": "dana.whitfield@example.com", "displayName": "Dana Whitfield" },
    { "email": "priya.nair@example.com", "displayName": "Priya Nair" }
  ]
}
```

## Notes

- `type: other` is the escape hatch for capture sources not yet enumerated;
  widening the enum is a `schema_version` minor bump (additive), not a major
  one.
- Multiple capture events may reference the same underlying interaction
  (e.g. a calendar `event-confirmation` plus a later voice-note debrief) —
  reconciling them is the filing engine's job via `interaction.md`'s
  `source-capture` field, not the capture event's.
- `occurred_at` is optional; the filing engine must not assume it exists.
  Existing 1.0.0 events (no `occurred_at`, plain-string `source`) remain valid
  under 1.1.0 — this bump is additive only, no migration required.
