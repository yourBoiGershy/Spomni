# package: connectors/gmail-out

version: 0.1.0

## Purpose

Session-driven fallback nudge delivery: emails any pending rendered
wake-up batch to the user's own Gmail address, and only that address. This
is the fallback channel when `## Notify channel: gmail-self` is resolved
(no beeper lane configured, or the user stated it explicitly) — the
headless `deliver-tick.sh` cannot call the first-party Gmail connector
itself (session-only surface), so it stages the rendered text under
`outbox/pending-gmail/` and this package's skill, run in a live session,
completes the send. Draft, never send is the standing rule for every
recipient except the user themselves; sending to the user's own stated
`gmail_address` is the self-notify exception
(`docs/DECISIONS.md#notify-self-is-a-send`).

## Provides

- `skills/gmail-self-notify/` — the session-driven send skill. Reads
  `<store>/profile.md ## Notify gmail_address` (stops with `skip: no
  gmail_address in ## Notify` if absent — never infers the address from
  any other source); sends each `<store>/outbox/pending-gmail/*.txt` file
  via `mcp__claude_ai_Gmail__send_message` to that address only; appends a
  `delivered.log` line and deletes the pending file on success. Symlinked
  into `.claude/skills/gmail-self-notify` per the repo's skills convention.

## Consumes

- `profile@^1.1` (core) — `## Notify` section, `gmail_address` bullet
- The first-party claude.ai Gmail connector (`mcp__claude_ai_Gmail__send_message`),
  session-only — no CLI, no shell-out, no credential of any kind stored in
  this repo
- `<store>/outbox/pending-gmail/*.txt` — written by `packages/connectors/
  scripts/deliver-tick.sh`, this package's sole input

## Owned paths

`packages/connectors/gmail-out/**`; at runtime: `<store>/outbox/
delivered.log` (append, shared with sibling delivery adapters under the
single-writer-per-line-source convention — each adapter only ever appends
its own lines) and consumes-then-deletes files under `<store>/outbox/
pending-gmail/`.

## Built by

Plan 33 (`docs/plans/2026-08-30-33-nudge-delivery-beeper-self.md`).
