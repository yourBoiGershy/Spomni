# package: connectors/beeper-in

version: 0.1.0

## Purpose

Read-only personal-chat capture: the user's own Beeper Client API (Desktop or
headless Server, same API surface — `docs/plans/2026-08-29-13-beeper-capture.md`)
polled for new messages across whichever bridged networks the user opts in, landed
as raw capture events in `inbox/`. Per-network enablement is opt-in with nothing
enabled by default (`docs/DECISIONS.md#beeper-personal-bridge`); the API's send
capability is never called from this sub-package (GET-only forever) — the
sole self-only send lives in `packages/connectors/beeper-out/`
(`docs/DECISIONS.md#notify-self-is-a-send`). Structuring/
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
  messages verbatim), `type: chat-message` per the capture-event 1.2.0 contract
  (source form `beeper-in/<network>`, `occurred_at` set to the newest message's
  timestamp in the batch).

## Backfill mode

`scripts/beeper-sweep.sh --backfill` (plan 24 U6; fixed under plan 26 D6) is
a one-shot onboarding mode, never wired into the sync scheduler (D4). It
resolves the onboarding backfill window via
`packages/connectors/scripts/resolve-backfill-window.sh <private-data-root>`
(abort on non-zero exit, no fallback window) and, per chat, paginates
messages backward (`direction=before`) from the chat's coverage-floor
cursor (see below) — or the newest page, if the chat has no incremental
capture at all yet — back to the window start. State is fully isolated
(D5): `data/connectors/beeper-in/backfill-cursors.tsv` + `backfill-last-
sweep`, siblings of the incremental `cursors.tsv`/`last-sweep`/`coverage-
floor.tsv` — this mode never reads or writes those incremental files. Runs
are logged to the same `runs.log` with a `backfill-` outcome-line marker
(e.g. `backfill-ok`, `backfill-partial`). Incremental invocation (no flag)
is unaffected except for the one-time coverage-floor write described below.

**D6 fix (plan 26).** The pre-fix version paginated backfill from the chat's
*incremental* cursor, which is that cursor's *newest*-page value — so
"before the incremental cursor" re-covered the very messages the
incremental lane's first newest-page fetch had just captured, and backfill
re-emitted a duplicate-subset capture event. Fix: the incremental lane's
first-ever fetch for a chat (no prior cursor — a single newest-page GET)
now also records that page's *oldest* cursor once to
`data/connectors/beeper-in/coverage-floor.tsv` (`chatID<TAB>oldestCursor`,
incremental-owned: written once, never advanced, never touched by
`--backfill`). Backfill's start bound per chat is: the coverage-floor
cursor when present (paginate `before` the floor, not the incremental
cursor) → else, for chats whose first incremental capture predates this
fix (no floor recorded), a legacy fallback that derives an oldest-covered
timestamp from that chat's existing `inbox/` capture events and excludes
messages at/after it → else (genuinely no prior incremental capture) the
original newest-page start, which was already correct there. If bridge
history is exhausted (`hasMore` false / no `oldestCursor`) before pagination
reaches the resolved window start, the run's `warn=` field records
`<chatID>=history-clamped@<oldest_ts>` rather than silently implying
full-window coverage.

## Import-pipeline conformance

Per `packages/core/contracts/import-pipeline.md` 1.0.0 ("Lane conformance is
declared, not assumed"), this lane's stages:

| Stage | Conforms | Notes |
|---|---|---|
| fetch | Yes | `beeper_get` is the sole HTTP call site (GET-only, no state-changing calls); raw item bodies never transcribed by the model — `fetch_new_messages`/`fetch_backfill_messages` run as shell/jq only. No on-disk raw-provider archive (`<store>/archive/raw/`) is written by this lane — see `api-notes.md`/build notes for why the beeper HTTP response isn't separately archived beyond the normalized `inbox/` event body. |
| normalize | Yes | Every fetch result is piped through the shared `packages/connectors/scripts/normalize-capture.sh`, envelope-only, one `chat-message` capture event per chat per sweep run, per capture-event 1.2.0. |

## Scheduling

This lane's sweep (`scripts/beeper-sweep.sh`) is scheduled by the shared sync
scheduler (`packages/connectors/scripts/sync-scheduler.sh`), config per core
contract `sync-lanes.md` (lane row `beeper`) — not a bespoke installer local
to this package. Plan 13's original hand-rolled launchd installer was
retired in plan 19; the scheduler's `install`/`uninstall`/`status`
subcommands now own this lane's launchd lifecycle.

## Provides

- Raw capture events in `inbox/` for the beeper personal-chat lane (subject to the
  capture-event contract's `type` enum; this lane uses `chat-message`)
- `fixtures/` — synthetic Beeper API response payloads (accounts, chat pages,
  message pages, an empty page) for sweep and lib tests to build against, offline
- `api-notes.md` — the verified API ground truth this package implements from
- `config.example.json` — the config schema template the user copies into their
  private data dir

## Consumes

- `capture-event@^1.2`, `connector-interface@^1`, `import-pipeline@^1` (core)
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
