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

Per `packages/attention/tests/fixtures/tier-drift-upward/` and
`packages/attention/specs/tier-drift.md`'s kind-horizon prefilter +
judgment-verdict shape (the old flat "dormant fires at N>=3" per-tier
cadence table is retired — plan 30):

- `people/owen-marsh.md` is tagged `tier: dormant` and, since plan 30's
  re-baseline, carries `kind: professional` (`kind_source:
  stated-by-user`, not expired) — a RHYTHMED kind, so the person is
  eligible for the UPWARD prefilter at all (an unkinded or no-rhythm-kind
  person would never reach judgment regardless of touchpoint count).
- `interactions/` has 5 filed touchpoints, all within the trailing 90 days
  of 2026-08-29 (2026-06-02, 2026-06-20, 2026-07-10, 2026-08-01,
  2026-08-25) — a raw count the prefilter treats as non-trivially elevated
  for a `dormant`-tagged, professional-kind person, admitting the
  candidate to the judgment pass (`specs/tier-drift.md` "### UPWARD drift
  prefilter").
- The judgment pass reads that evidence (no confirmed `user-model.md` is on
  file in this fixture, so no user-model priors are read — `priors:
  user-model: none` per the spec's "draft models are never read" rule) and
  verdicts UPWARD drift, proposing `dormant` -> `active`.
- `expected-proposal.md` in the fixture is the hand-authored reference: the
  detector should write exactly one new `wakeups/*.md` with
  `origin: signal`, `status: pending`, `people: ["[[owen-marsh]]"]`, a
  `why`/`## Context` naming the observed frequency and proposing
  `dormant` -> `active`, and a breakdown string per
  `relationship-scoring.md`'s "## Breakdown string" format (never writing
  `people/owen-marsh.md#tier` itself).

## Graders

1. `01-proposal-created.py` — exactly one new file appears under the worked
   store's `wakeups/`, with frontmatter matching the shape above (tolerant
   of the generated `id`/`due`/`source-signal` values, which are run-date
   dependent and not byte-fixed by the fixture).
2. `02-never-demoted.py` — `people/owen-marsh.md` in the worked store is
   byte-identical to the fixture's copy. This is the never-demote guardrail
   as code: the detector proposes, it never writes `tier`.
