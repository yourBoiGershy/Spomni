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
  event-confirmation emails → typed capture events; transport is the first-party
  claude.ai Gmail connector (session-driven MCP tools), read-only
- `calendar-in/` — multi-calendar read-only pull → normalized event artifacts;
  transport is the first-party claude.ai Google Calendar connector
  (session-driven MCP tools), read-only
- `contacts-in/` — Google Contacts (birthdays, emails) → contact artifacts
- `file-out/` — built (plan 33): always-on outbox audit, appends every fired
  batch to `<store>/outbox/<date>.md`, no config, no network
- `gmail-out/` — built (plan 33): session-driven `gmail-self-notify` skill,
  emails staged `outbox/pending-gmail/*.txt` to the user's OWN address only
- `beeper-in/` — the user's own Beeper Client API (personal chats across bridged
  networks, opt-in per network) → normalized capture events
- `beeper-out/` — self-only send to the user's own Beeper note-to-self chat;
  the single exception to draft-never-send, DECISIONS `notify-self-is-a-send`;
  refuses any chat id not stated in `profile.md ## Notify`

Shared input tooling (e.g. `scripts/normalize-capture.sh`, and the sync scheduler
`scripts/sync-scheduler.sh` + `scripts/sync-lib.sh`) lives at the package root.
`scripts/resolve-backfill-window.sh` (plan 24) resolves the onboarding-backfill
window from `<data-dir>/config/onboarding-backfill.tsv` for all lane backfill modes.

## Provides

- Capture events in `inbox/` (single writer for that dir), quarantine convention,
  processed-message ledger
- Normalized calendar-event and contact artifacts for `ingestion`
- The output-adapter delivery lanes
- The shared sync scheduler (`scripts/sync-scheduler.sh` + `scripts/sync-lib.sh`,
  plan 19) — one configurable, restart-safe launchd runner for all input-lane
  sweeps, replacing per-lane bespoke installers (e.g. beeper-in's plan-13 one)
- The headless MCP-lane tick wrapper (`scripts/mcp-lane-tick.sh`, plan 28) —
  runs a capped `claude -p` session per scheduled tick so gmail-in/calendar-in
  (first-party MCP fetch) can be lanes in `lanes.tsv`; `preflight` verifies
  connector tools before a lane is enabled.
- The delivery tick `scripts/deliver-tick.sh` (renders undelivered
  `wakeups/fired/` batches via core `render-nudge-cards.sh`, writes outbox,
  sends via the configured channel, idempotent through
  `<store>/outbox/delivered.log`; scheduled as the `notify` lane)

## Consumes

- `capture-event@^1`, `connector-interface@^1`, `sync-lanes@^1.1.0` (adds
  `{{REPO_ROOT}}`/`{{DATA_DIR}}`/`{{PRIVATE_DATA_ROOT}}`/`{{STORE_DIR}}`/
  `{{CLAUDE_BIN}}` command placeholders, expanded per-tick by `sync-lib.sh`),
  `import-pipeline@^1`, `profile@^1.1` (`## Notify`, read), `nudge-card@^1`
  (core)
- First-party MCP servers / Claude connectors only (see DECISIONS.md:
  first-party-mcp-only)

## Owned paths

`packages/connectors/**`; at runtime: the private data dir's `inbox/` (writes),
all outbound delivery, and `<store>/outbox/**` incl. `delivered.log` and
`pending-gmail/`.

## Built by

Plans 07 (file-out, gmail-out — scaffolding), 13 (beeper-in), 17 (gmail-in,
calendar-in; docs/plans/2026-08-29-17-composio-retirement-direct-google-lanes.md),
33 (file-out, gmail-out built out; beeper-out; deliver-tick.sh).
