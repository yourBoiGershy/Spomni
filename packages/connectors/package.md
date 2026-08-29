# package: connectors

version: 0.1.0

## Purpose

All outside-world I/O, both directions — and deliberately dumb. Input connectors fetch
from a source and write normalized capture events into `inbox/`; output connectors take
rendered content plus a destination config and deliver it. Connectors never interpret,
match, rank, or file — that intelligence lives in `ingestion` and `attention`
("dumb edges, smart middle").

## Sub-packages

Each subdirectory is a sub-package and gets its own mini `package.md` when built:

- `gmail-in/` — subject-tagged self-emails (voice notes), LinkedIn notification emails,
  event-confirmation emails → typed capture events
- `calendar-in/` — multi-calendar read-only pull → normalized event artifacts
- `contacts-in/` — Google Contacts (birthdays, emails) → contact artifacts
- `file-out/` — renders batches to `data/outbox/` + in-session display
- `gmail-out/` — emails batches to the user's OWN address only (hard-constrained;
  draft-never-send)
- `beeper-in/` — the user's own Beeper Client API (personal chats across bridged
  networks, opt-in per network) → normalized capture events

Shared input tooling (e.g. `scripts/normalize-capture.sh`) lives at the package root.

## Provides

- Capture events in `inbox/` (single writer for that dir), quarantine convention,
  processed-message ledger
- Normalized calendar-event and contact artifacts for `ingestion`
- The output-adapter delivery lanes

## Consumes

- `capture-event@^1`, `connector-interface@^1` (core)
- First-party MCP servers / Claude connectors only (see DECISIONS.md:
  first-party-mcp-only)

## Owned paths

`packages/connectors/**`; at runtime: the private data dir's `inbox/` (writes) and all
outbound delivery.

## Built by

Plans 02 (gmail-in), 04 (calendar-in, connector half), 07 (file-out, gmail-out),
12 (beeper-in).
