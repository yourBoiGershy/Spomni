# package: connectors/composio-in

version: 0.1.0

## Purpose

Broad, read-only capture across the user's own accounts through one aggregator — the
user's Composio account (`docs/DECISIONS.md#composio-hub`) — landed as raw capture
events in `inbox/`. Breadth over depth: as many data points as possible through as few
connector setups as possible. Structuring/filing is explicitly out of scope here (that's
`ingestion`); this package only guarantees access + lossless raw capture, per
"dumb edges, smart middle."

## CLI call convention

Sweeps shell out to the Composio CLI rather than registering an MCP server:

```
composio execute <TOOL_SLUG> -d '{...}'
```

- `<TOOL_SLUG>` examples: `GMAIL_FETCH_EMAILS`, `GOOGLECALENDAR_EVENTS_LIST`,
  `LINKEDIN_GET_MY_INFO`.
- Large results are **not** returned inline — the CLI writes them to a temp JSON file
  and returns `{ "storedInFile": true, "outputFilePath": "/tmp/..." }` in place of the
  payload. Sweeps must handle both the inline-`data` shape and the file-backed shape;
  fixtures in this package model the inline shape (representative fields only) since
  the two are equivalent once the file is read.
- This package is **read-only against every linked account** — no send tooling, ever
  (per `docs/DECISIONS.md#draft-never-send`). Lanes covered today: Gmail, Google
  Calendar, LinkedIn (official member API surface only — no connections list, no
  messages, no notifications; see `docs/DECISIONS.md#tos-clean-signals-only`).

## Provides

- Raw capture events in `inbox/` for the gmail, calendar, and linkedin lanes (subject
  to the capture-event contract's `type` enum — `voice-note`,
  `linkedin-notification`, `event-confirmation`, `other`)
- Per-lane sweep skills (`skills/gmail-sweep`, `skills/calendar-sweep`,
  `skills/linkedin-sweep`) that dedup against a connector-local ledger, never the
  shared store
- This fixture pack (`fixtures/`) — synthetic raw payloads shaped like
  `composio execute` output, for sweep and normalizer tests to build against

## Consumes

- `capture-event@^1`, `connector-interface@^1` (core)
- The user's Composio CLI session (`composio login` / `composio link` done
  out-of-band by the user; this package assumes an already-linked, ACTIVE session for
  `gmail`, `googlecalendar`, `linkedin`)

## Owned paths

`packages/connectors/composio-in/**`; at runtime: `inbox/` (writes, shared with sibling
input connectors under the single-writer rule for that directory) plus this package's
own local checkpoint/ledger files (never in the shared store, per
`docs/DECISIONS.md#code-data-separation`).

## Built by

Plan 08 (docs/plans/2026-08-29-08-composio-access-layer.md).
