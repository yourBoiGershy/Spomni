# Expected outcome: signal logged, promotion held

This scenario's expected output is exactly one new signal event file and
**no** new wake-up file.

## Exact assertion

Given the input state in this scenario directory (`people/callum-reyes.md`,
one filed message interaction `interactions/2026-08-24-callum-reyes.md`
containing the vague line "We should hang out sometime!"), a future
scheduling-intent-detector test should assert:

1. Running the detector against this scenario's store produces exactly one
   new file under `wakeups/signals/` —
   `20260829T090000Z-scheduling-intent-callum-reyes.md` (see
   `expected/signal-event.md`) — with `confidence: low`.
2. Running promotion against that signal produces **zero** new files under
   `wakeups/` (no `event-proposal`, no `nudge`). Low confidence never
   promotes, per `packages/attention/specs/scheduling-intent.md`'s pinned
   rule: "Low never promotes."
3. `wakeups/` (proposal-level, not the `signals/` sub-directory) is empty
   both before and after the run — this scenario ships no pre-existing
   `wakeups/` directory since there is nothing there to begin with.
4. No slot selection is attempted at all — slot arithmetic only runs for
   medium/high confidence signals headed toward promotion, so this scenario
   intentionally ships no filed calendar interactions (unlike the
   `clear-intent` sibling fixture, where free/busy calendar context is
   load-bearing).

## Assumed "today"

All dates in this fixture set are relative to "today" = **2026-08-29**,
matching the sibling `clear-intent` and `declined-proposal` scenarios (see
this directory's parent `README.md`).
