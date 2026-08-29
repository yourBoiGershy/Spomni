# Expected outcome: silence

This scenario's expected output is the **absence** of a new wake-up file.

## Exact assertion

Given the input state in this scenario directory (`people/owen-marsh.md` at
`tier: dormant`, five `interactions/` entries in the trailing quarter — the
same frequency signal as the `tier-drift-upward` sibling fixture — plus one
pre-existing `wakeups/2026-07-30-owen-marsh.md` at `status: dismissed`,
`dismiss-reason: not-this-signal-type`, dated 30 days before "today"
2026-08-29), a future tier-drift-detector test should assert:

1. Running the tier-drift detector against this scenario's store produces
   **zero** new files under `wakeups/`.
2. `wakeups/` contains exactly the one pre-existing file
   (`2026-07-30-owen-marsh.md`) before and after the run — byte-identical,
   untouched by the detector (it is not the detector's file to rewrite; only
   `packages/attention`'s lifecycle ops/sweep touch existing wake-up files,
   and this one is already terminal).
3. `people/owen-marsh.md#tier` remains `dormant` — unconditionally; a
   declined proposal never triggers an automatic tier write, and this fixture
   additionally checks that redundant re-proposal doesn't happen either.

## Assumed threshold (open question in plan 11 — flag for wave F reconciliation)

The plan does not pin an exact cooldown window for "don't re-propose a
tier-drift bump that was just declined." This fixture assumes: **a
tier-drift proposal dismissed with `dismiss-reason: not-this-signal-type`
suppresses a new proposal for the same person for 90 days from that
dismiss's `fired-on` date.** 30 days (this fixture's gap) falls well inside
that window, so silence is the unambiguous expected outcome regardless of
the exact cooldown chosen, as long as it is >= 30 days. If
`packages/attention/specs/tier-drift.md` lands with a different cooldown
value, only the boundary-case fixture (not this one) would need
re-validation — this fixture's 30-day gap is safely inside any reasonable
window.
