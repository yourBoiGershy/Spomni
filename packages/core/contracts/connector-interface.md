# Contract: connector interface

`schema_version: 1.0.0`

## Scope

This contract governs `packages/connectors/*` — both directions of
outside-world I/O. It does not define a store file format on its own; it
defines the two obligations connectors must meet, and points at the
contracts that carry the actual payload shapes. Per `docs/PROJECT-CONTEXT.md`
("dumb edges, smart middle"): **connectors never interpret, match, rank, or
file.** All judgment lives in `ingestion`, `attention`, and `query`. Input
connectors implement the fetch and normalize stages of
`import-pipeline.md`.

## Input connectors (`packages/connectors/*-in`)

**Obligation:** write valid capture events into `inbox/`. That is the entire
job — see `capture-event.md` for the exact file shape.

- Sole writer of `inbox/` (single-writer rule, `docs/PROJECT-CONTEXT.md`).
- Must not resolve `participant-hints` to person slugs, must not summarize
  or reformat the body, must not decide what's "worth" capturing beyond the
  connector's own fetch scope (e.g. calendar-in pulls all calendars per
  `docs/DECISIONS.md#multiple-google-calendars`, it doesn't filter for
  "important" meetings).
- One capture event per distinguishable captured item. A connector polling
  the same source repeatedly must not re-emit duplicate capture events for
  material already written (dedup on the source's own stable ID, e.g. Gmail
  message ID, stored in the capture event's `id` derivation or tracked in
  the connector's own local checkpoint — never in the shared store).

### Example: what an input connector hands to the filing engine

An input connector's unit of work output is exactly one `inbox/*.md` file
conforming to `capture-event.md`. No other contract applies on the input
side — see that file for the full example.

## Output connectors (`packages/connectors/*-out`)

**Obligation:** accept a rendered-content delivery request and a destination
config, and deliver it. Nothing more — no choosing what to send, no editing
copy, no deciding timing. Those decisions happen upstream (attention decides
*when*; whatever renders the draft, typically query/attention, decides
*what the words say*).

### Delivery request shape

Output connectors receive an in-memory (or file-passed) delivery request —
this is not a store artifact, so it has no `inbox/`/`people/` location, but
it is versioned the same way for the same compatibility reasons.

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this request conforms to. |
| `wakeup-id` | string or `null` | no | The `wakeups/<id>` this delivery corresponds to, when applicable (fired wake-ups, briefs tied to a wake-up). `null` for ad hoc deliveries (e.g. a query answer rendered to a file). |
| `rendered` | object | yes | The already-composed content. At minimum `{ "subject": string \| null, "body": string }`. The output connector does not alter this text. |
| `destination` | object | yes | Connector-specific config, e.g. `{ "type": "gmail-out", "to": "user@example.com" }` or `{ "type": "file-out", "path": "~/Desktop/nudges.md" }`. The `type` key names which output connector handles it; each connector defines its own remaining keys. |

### Example

```json
{
  "schema_version": "1.0.0",
  "wakeup-id": "2026-09-20-dana-whitfield",
  "rendered": {
    "subject": null,
    "body": "Hey Dana! How's Berlin treating you — all unpacked and settled into the new role yet? Would love to hear how the partnerships team is shaping up."
  },
  "destination": {
    "type": "file-out",
    "path": "~/Desktop/pending-nudges.md"
  }
}
```

- Per `docs/DECISIONS.md#draft-never-send`: no output connector may deliver
  outreach directly to a third party without a human send action in
  between. `gmail-out` composing a draft in the user's own drafts folder is
  compliant; `gmail-out` sending on the user's behalf is not — that
  boundary is enforced at the connector implementation level, not by this
  contract's shape, but it is binding regardless.

## Notes

- Connectors depend only on `core`'s contracts (this file plus
  `capture-event.md`); they never import another sibling package's
  internals, per the no-overlap rules in `docs/PROJECT-CONTEXT.md`.
- Widening `destination`'s per-type keys is each connector's own concern and
  does not require a `schema_version` bump here; changing the required
  top-level fields (`rendered`, `destination`) does.
