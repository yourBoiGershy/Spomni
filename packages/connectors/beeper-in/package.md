# package: connectors/beeper-in

version: 0.1.0

## Purpose

Read-only personal-chat capture: the user's own Beeper Client API (Desktop or
headless Server, same API surface — `docs/plans/2026-08-29-13-beeper-capture.md`)
polled for new messages across whichever bridged networks the user opts in, landed
as raw capture events in `inbox/`. Per-network enablement is opt-in with nothing
enabled by default (`docs/DECISIONS.md#beeper-personal-bridge`); the API's send
capability is never called (`docs/DECISIONS.md#draft-never-send`). Structuring/
filing is out of scope here (`ingestion`'s job) — this package only guarantees
access + lossless raw capture, per "dumb edges, smart middle."

## API call convention

Sweeps call the Beeper Client API directly over HTTP (`base_url`, default
`http://127.0.0.1:23373`, Bearer token) via a single shared `beeper_get` function —
GET only, no state-changing calls, ever. See `api-notes.md` for the full endpoint
list, shapes, cursor semantics, and the chat-ID URL-encoding caveat.

- `GET /v1/info`, `GET /v1/accounts`, `GET /v1/chats`,
  `GET /v1/chats/{chatID}/messages` are the only allowed paths.
- Cursor-based catch-up: each chat's `newestCursor` is persisted locally and
  advanced only after its capture event is normalized successfully — lossy-
  tolerant, no retries, no error spam on transport failure.
- One capture event per chat per sweep run (envelope-only; batches that chat's new
  messages verbatim), `type: other` per the capture-event contract's minimal-typing
  rule (widening the enum for chat threads is a future core minor bump, not this
  lane).

## Provides

- Raw capture events in `inbox/` for the beeper personal-chat lane (subject to the
  capture-event contract's `type` enum; this lane uses `other`)
- `fixtures/` — synthetic Beeper API response payloads (accounts, chat pages,
  message pages, an empty page) for sweep and lib tests to build against, offline
- `api-notes.md` — the verified API ground truth this package implements from
- `config.example.json` — the config schema template the user copies into their
  private data dir

## Consumes

- `capture-event@^1`, `connector-interface@^1` (core)
- The user's own Beeper Desktop/Server Client API + a user-created Bearer token
  (out-of-band; token lives under the private data dir, never in this repo, per
  `docs/DECISIONS.md#code-data-separation`)

## Owned paths

`packages/connectors/beeper-in/**`; at runtime: `inbox/` (writes, shared with
sibling input connectors under the single-writer rule for that directory) plus
this package's own local state under `data/connectors/beeper-in/` (token,
config, cursors, logs — never in the shared store).

## Built by

Plan 13 (`docs/plans/2026-08-29-13-beeper-capture.md`).
