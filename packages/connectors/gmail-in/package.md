# package: connectors/gmail-in

version: 0.1.0

## Purpose

Read-only Gmail capture: subject-tagged self-emails (voice notes, `[ra]`
subject marker), LinkedIn notification emails, and ordinary email — landed as
typed capture events in `inbox/`. Transport is the first-party claude.ai
Gmail connector, called **in-session** via its MCP tools
(`mcp__claude_ai_Gmail__*` — VERIFY-LIVE, see
`skills/gmail-sweep/SKILL.md` step 0), not a CLI or shell-out; there is no
standalone Gmail API client in this package. Structuring/filing is out of
scope here (`ingestion`'s job) — this package only guarantees access + lossless
raw capture, per "dumb edges, smart middle."

## Call convention

The `gmail-sweep` skill instructs the running Claude session to call
`mcp__claude_ai_Gmail__*` tools directly (list/search/get-class only) and pipe
each item's result through Bash into
`packages/connectors/scripts/normalize-capture.sh`. No tool name below is
verified against a live server yet — every one carries an explicit
`VERIFY-LIVE` marker in the skill file, and step 0 of every sweep run
re-enumerates the actually-available tool set before doing anything else; if
the live names differ from what's written, the sweep stops and reports rather
than guessing.

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
- `fixtures/` — best-guess, synthetic-PII-only first-party Gmail tool output
  shapes for offline sweep-logic development and test fixtures; corrected
  against live shapes at Phase 3 live-verify (see `fixtures/README.md`)
- `scripts/classify.sh` — deterministic, offline-testable typing helper

## Consumes

- `capture-event@^1.2`, `connector-interface@^1` (core)
- `packages/connectors/scripts/normalize-capture.sh` (shared normalizer, this
  package's parent)
- An authenticated, in-session first-party Gmail connector (the user's own
  Gmail account, linked via claude.ai connectors — out-of-band, no token or
  credential of any kind lives in this repo)

## Owned paths

`packages/connectors/gmail-in/**`; at runtime: `inbox/` (writes, shared with
sibling input connectors under the single-writer rule for that directory) plus
this package's own local state under `data/connectors/gmail/` (checkpoint,
processed-message ledger, raw-item archive — never in the shared store).

## Out of scope (deferred)

Backfill mode and a one-shot contacts-seed are deferred by Plan 17 pending a
Phase 3 check of whether the first-party Gmail connector's tool surface
offers equivalent tooling (date-range query beyond the 30-day checkpoint
bound, contacts listing). Scheduling/recurring invocation is Plan 19's job —
this package only guarantees the sweep is invokable as a single skill run.

## Built by

Plan 17 (`docs/plans/`, 2026-08-29 direct-Google-lanes plan).
