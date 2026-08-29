---
tier: skill
store: packages/attention/tests/fixtures/tier-drift-upward
expected: packages/attention/evals/cases/tier-drift-upward/expected
runnable-when: "05"
---
Act as the tier-drift detector specified in
`packages/attention/specs/tier-drift.md` and run it against `./store` as of
today, 2026-08-29. `./store` has `people/`, `interactions/`, and an empty
`wakeups/`. Evaluate every person in `./store/people/` for UPWARD or QUIET
tier drift per the spec's thresholds and, if a divergence fires, write the
resulting proposal wake-up into `./store/wakeups/` (plus its signal event
under `./store/wakeups/signals/` if your implementation of the spec produces
one). Do not write to `./store/people/` under any circumstance — tier
changes are never this detector's job; a divergence is surfaced only as a
proposal wake-up for the user to confirm or decline.
