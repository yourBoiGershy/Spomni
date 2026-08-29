# package: connectors/calendar-in

version: 0.1.0

## Purpose

Read-only Google Calendar capture: every calendar the user's Google account
can see (work + personal, per `docs/DECISIONS.md#multiple-google-calendars`)
swept for events, landed as raw capture events in `inbox/`. Transport is the
first-party claude.ai Google Calendar connector — an in-session MCP tool set,
not a CLI or an out-of-band API key — so sweeps are **session-driven**: the
`calendar-sweep` skill instructs the running Claude session to call the MCP
tools directly, then pipe each event through `normalize-capture.sh` via Bash.
Structuring/filing is out of scope here (`ingestion`'s job) — this package
only guarantees access + lossless raw capture, per "dumb edges, smart
middle."

## MCP call convention

Sweeps call the `mcp__claude_ai_Google_Calendar__*` tool set exposed to the
session once the user has linked the connector. Tool names verified
in-session 2026-08-29 (see Plan 17, the 2026-08-29 direct-Google-lanes plan
under `docs/plans/`, "Transport facts").

**Allowed (read-only) tools — the only ones this lane ever calls:**

- `list_calendars` — enumerate every calendar on the account.
- `list_events` — page through a calendar's events over a time window.
- `search_events` — available for ad hoc lookups; not used by the standing
  sweep, which relies on `list_events` windowing instead.
- `get_event` — fetch a single event by id, if ever needed for a targeted
  re-check.

**Banned tools — never called by this lane, ever** (draft-never-send,
read-only-against-the-account hard rule, per `docs/DECISIONS.md#draft-
never-send`):

- `create_event`
- `update_event`
- `delete_event`
- `respond_to_event`

`suggest_time` is part of the verified tool set but unused by this lane (it
is neither a read nor a mutation this sweep needs).

## Provides

- Raw capture events in `inbox/` for the calendar lane (`source: calendar-in/
  calendar`, `type: calendar-event` per the capture-event 1.2.0 contract)
- `skills/calendar-sweep/SKILL.md` — the session-driven sweep procedure
- `scripts/extract-hints.sh` — event JSON → `participant-hints` lines
- `fixtures/` — synthetic MCP tool-output shapes (calendars list, timed
  event, all-day event) for offline testing of `extract-hints.sh` and the
  capture test suite

## Consumes

- `capture-event@^1.2`, `connector-interface@^1` (core)
- The user's own first-party claude.ai Google Calendar connector, linked
  in-session (out-of-band; no credentials live in this repo, per
  `docs/DECISIONS.md#code-data-separation`)

## Owned paths

`packages/connectors/calendar-in/**`; at runtime: `inbox/` (writes, shared
with sibling input connectors under the single-writer rule for that
directory) plus this package's own local state under
`data/connectors/calendar/` (dedup ledger, checkpoint — never in the shared
store).

## Built by

Plan 17 (`docs/plans/`, 2026-08-29 direct-Google-lanes plan).
