---
tier: skill
store: packages/attention/tests/fixtures/declined-proposal
expected: packages/attention/evals/cases/declined-proposal/expected
runnable-when: "05"
---
Act as the tier-drift detector specified in
`packages/attention/specs/tier-drift.md` and run it against `./store` as of
today, 2026-08-29. `./store` has `people/`, `interactions/`, and a
`wakeups/` directory containing one pre-existing wake-up. Evaluate every
person in `./store/people/` for UPWARD or QUIET tier drift per the spec's
thresholds, applying the declined-pairing suppression rule against any
prior dismissed tier-drift wake-ups you find in `./store/wakeups/` before
proposing anything new. Do not write to `./store/people/` under any
circumstance, and do not modify any existing file under `./store/wakeups/`.
