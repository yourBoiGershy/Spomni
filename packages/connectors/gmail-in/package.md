# package: connectors/gmail-in

version: 0.1.0

## Purpose

Read-only Gmail capture: subject-tagged self-emails (voice notes, `[ra]`
subject marker), LinkedIn notification emails, and ordinary email — landed as
typed capture events in `inbox/`. Transport is the first-party claude.ai
Gmail connector, called **in-session** via its MCP tools
(`mcp__claude_ai_Gmail__*`, live-verified 2026-08-29 — see
`skills/gmail-sweep/SKILL.md` step 0), not a CLI or shell-out; there is no
standalone Gmail API client in this package. Structuring/filing is out of
scope here (`ingestion`'s job) — this package only guarantees access + lossless
raw capture, per "dumb edges, smart middle."

## Call convention

The `gmail-sweep` skill instructs the running Claude session to call
`mcp__claude_ai_Gmail__search_threads` (thread-level search, `pageSize` max
50, `pageToken` pagination), `mcp__claude_ai_Gmail__get_thread`, and
`mcp__claude_ai_Gmail__get_message` (both with `messageFormat:
"PLAIN_TEXT"` recommended) directly, and pipe each item's result through
Bash into `packages/connectors/scripts/normalize-capture.sh`. These names
and the PLAIN_TEXT recommendation are live-verified 2026-08-29 (Plan 17,
Phase 3 / U10); step 0 of every sweep run still re-enumerates the
actually-available tool set before doing anything else, and stops and
reports rather than guessing if the live surface has since changed.

**Read-only, hard constraint** (`docs/DECISIONS.md#draft-never-send`): the
sweep may call only list/search/get-class Gmail tools. Any tool whose name
implies send, draft, modify, label, or trash/delete a message is banned —
once step 0 enumerates the live tool set, every such tool found is named
explicitly as banned in the skill file (never called, not even to test).

## Provides

- Raw capture events in `inbox/` for the gmail lane (source `gmail-in/gmail`),
  typed `email` / `voice-note` / `linkedin-notification` per
  `scripts/classify.sh`'s rules, subject to the capture-event contract's
  `type` enum
- `fixtures/` — live-verified (2026-08-29), synthetic-PII-only first-party
  Gmail tool output shapes for offline sweep-logic development and test
  fixtures (see `fixtures/README.md`)
- `scripts/classify.sh` — deterministic, offline-testable typing helper

## Consumes

- `capture-event@^1.2`, `connector-interface@^1`, `import-pipeline@^1` (core)
- `packages/connectors/scripts/normalize-capture.sh` (shared normalizer, this
  package's parent)
- An authenticated, in-session first-party Gmail connector (the user's own
  Gmail account, linked via claude.ai connectors — out-of-band, no token or
  credential of any kind lives in this repo)

## import-pipeline conformance

| Stage | Conforms | Mechanism |
|---|---|---|
| fetch | Yes (`import-pipeline@1.0.0`, D5) | `search_threads`/`get_thread` requested at max page size so results land on disk as a saved tool-result file; session handles the file path only (archive via `cp`, classify/hints/body extraction via jq + `scripts/extract-email-body.sh`). Inline residual (small final page) written verbatim to a temp file and counted as `inline-spilled` in the run summary. See `skills/gmail-sweep/SKILL.md` step 2. |
| normalize | Yes (`import-pipeline@1.0.0`) | `packages/connectors/scripts/normalize-capture.sh --file <body-file>`, where `<body-file>` is written by `scripts/extract-email-body.sh` — never model stdin. |

## Owned paths

`packages/connectors/gmail-in/**`; at runtime: `inbox/` (writes, shared with
sibling input connectors under the single-writer rule for that directory) plus
this package's own local state under `data/connectors/gmail/` (checkpoint,
processed-message ledger, raw-item archive — never in the shared store).

## Backfill mode

A separate, explicitly-invoked one-shot mode of `gmail-sweep` (Plan 24, U4)
for onboarding: sweeps a wider historical window resolved via
`packages/connectors/scripts/resolve-backfill-window.sh`, using its own
isolated state (`data/connectors/gmail/backfill-checkpoint` +
`backfill-processed.log`, sibling to the incremental files) so it never
reads or writes the incremental `checkpoint`/`processed.log`. Never a
`sync-lanes` scheduler row — invoked only by explicit request. See
`skills/gmail-sweep/SKILL.md`'s "Backfill mode" section for the full
mechanics (window resolution, dual-ledger dedup, checkpoint-advance rule).

## Out of scope (deferred)

Date-range querying (`after:`/`before:` in `search_threads`) also underpins
the backfill mode above, which was deferred by Plan 17 and is now built by
Plan 24. A one-shot contacts-seed is **permanently deferred**, not
pending-verification: live-verified 2026-08-29, no contacts/People tool
exists on this connector's surface at all (see `skills/gmail-sweep/SKILL.md`
step 0's "Not present on this surface" note); revisit only if the surface
itself changes. Scheduling/recurring invocation is Plan 19's job — this
package only guarantees the sweep is invokable as a single skill run.

## Built by

Plan 17 (`docs/plans/`, 2026-08-29 direct-Google-lanes plan).
