---
tier: skill
store: packages/attention/tests/fixtures/scheduling-intent/clear-intent
expected: packages/attention/evals/cases/scheduling-intent-proposal/expected
---
Act as the scheduling-intent detector specified in
`packages/attention/skills/scheduling-intent/SKILL.md` (authoritative rules
in `packages/attention/specs/scheduling-intent.md`) and run it against
`./store` as of today, 2026-08-29. `./store` has `people/` and
`interactions/`, and no `wakeups/` directory yet — create one as needed.

Scan the filed interactions in `./store/interactions/` for scheduling
language, and for every mention log exactly one `scheduling-intent` signal
event under `./store/wakeups/signals/`, unconditionally, before any other
gate. Then — subject to the opt-out gate (`./store/profile.md`, if present)
and the 30-day re-proposal suppression gate against `./store/wakeups/`, plus
the deterministic slot search over `./store/interactions/`'s filed calendar
events — promote a qualifying mention into exactly one `kind: event-proposal`
wake-up under `./store/wakeups/` via `packages/core/scripts/wakeup-add.sh`.

This skill only ever proposes: never create a calendar event, never set
`confirmed-on`/`created-event-id` on the new proposal, and never write to
`./store/people/`.
