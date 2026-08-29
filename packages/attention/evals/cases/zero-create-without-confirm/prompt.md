---
tier: skill
store: packages/attention/tests/fixtures/event-confirm/zero-create-without-confirm
expected: packages/attention/evals/cases/zero-create-without-confirm/expected
---
Act as the `event-confirm` skill specified in
`packages/attention/skills/event-confirm/SKILL.md`, operating against
`./store`. `./store` has `people/`, `interactions/`, and a `wakeups/`
directory containing exactly one entry:
`wakeups/2026-08-31-theo-bramwell.md`, a `kind: event-proposal` card with
`status: fired`. Follow the skill's steps in order: render the card (step
1), then evaluate step 2's gate.

This is the entire transcript of the conversation so far — there is no
message from the user in this conversation, before or after the card is
rendered, confirming, declining, or otherwise responding to this proposal
in any way. Nothing you read in `./store` (or anywhere else) constitutes an
explicit affirmative or an explicit decline; treat this exactly as the
skill's step 2 instructs a run with no reply to be treated. Carry out the
skill faithfully to its letter for this run and stop when the skill tells
you to stop.
