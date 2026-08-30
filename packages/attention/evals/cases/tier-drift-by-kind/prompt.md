---
tier: skill
store: packages/attention/tests/fixtures/tier-drift-by-kind
expected: packages/attention/evals/cases/tier-drift-by-kind/expected
runnable-when: "06"
---
Act as the tier-drift detector specified in
`packages/attention/specs/tier-drift.md` and run it against `./store` as of
today, 2026-08-30. `./store` has `people/`, `interactions/`, and an empty
`wakeups/`. Apply the kind-horizon prefilter from the spec's "## Prefilter"
section to every person in `./store/people/` before running the judgment
pass on whichever candidates clear it — a person whose kind is not
RHYTHMED, or whose `kind_expires` has passed, or whose `days_since_last`
has not yet exceeded their kind's soft horizon never enters judgment at
all. For any person the prefilter rules out, log a `no-drift` line in
`./store/wakeups/signals/scan-log.md` naming the person and the reason
(expired kind, no-rhythm kind, or inside-horizon) rather than writing a
signal event for them. For any candidate that clears the prefilter, run
the judgment pass and, on divergence, write the resulting proposal
wake-up into `./store/wakeups/` (plus its signal event under
`./store/wakeups/signals/`), each carrying the full breakdown string per
`packages/core/contracts/relationship-scoring.md`'s "## Breakdown string"
format. `./store` has no `user-model.md`, so disclose `user-model: none`
in every breakdown's priors segment rather than fabricating priors. Do not
write to `./store/people/` under any circumstance — tier changes are never
this detector's job; a divergence is surfaced only as a proposal wake-up
for the user to confirm or decline.
