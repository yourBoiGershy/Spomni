# Expected outcome: one UPWARD-drift proposal, never-demote guardrail intact

This case's `graders/` derive their assertions directly from the fixture
(`packages/attention/tests/fixtures/tier-drift-upward/expected-proposal.md`
and `people/owen-marsh.md`) rather than from a byte-diffable `expected/`
store — the detector's own proposal wake-up gets a fresh `id`/`due`/
`source-signal` timestamp each run, so exact-diffing the whole store would
fail on non-substantive fields. This directory exists only to satisfy the
`expected` frontmatter field the T3 runner (`eval-run-skill.sh`) requires;
it is not consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from the fixture)

Per `packages/attention/tests/fixtures/tier-drift-upward/`:

- `people/owen-marsh.md` is tagged `tier: dormant`.
- `interactions/` has 5 filed touchpoints, all within the trailing 90 days of
  2026-08-29 (2026-06-02, 2026-06-20, 2026-07-10, 2026-08-01, 2026-08-25).
- Per `specs/tier-drift.md`'s UPWARD table, `dormant` fires at `N >= 3`
  touchpoints in the trailing 90 days; 5 >= 3, so UPWARD drift fires.
- `expected-proposal.md` in the fixture is the hand-authored reference: the
  detector should write exactly one new `wakeups/*.md` with
  `origin: signal`, `status: pending`, `people: ["[[owen-marsh]]"]`, and a
  `why`/`## Context` naming the observed frequency and proposing
  `dormant` -> `active` (never writing `people/owen-marsh.md#tier` itself).

## Graders

1. `01-proposal-created.py` — exactly one new file appears under the worked
   store's `wakeups/`, with frontmatter matching the shape above (tolerant
   of the generated `id`/`due`/`source-signal` values, which are run-date
   dependent and not byte-fixed by the fixture).
2. `02-never-demoted.py` — `people/owen-marsh.md` in the worked store is
   byte-identical to the fixture's copy. This is the never-demote guardrail
   as code: the detector proposes, it never writes `tier`.
