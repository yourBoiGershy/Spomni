# Expected outcome: silence

This case's `graders/` derive their assertions directly from the fixture
(`packages/attention/tests/fixtures/declined-proposal/expected/README.md`,
`wakeups/2026-07-30-owen-marsh.md`, and `people/owen-marsh.md`) rather than
from a byte-diffable `expected/` store. This directory exists only to
satisfy the `expected` frontmatter field the T3 runner
(`eval-run-skill.sh`) requires; it is not consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from the fixture)

Per `packages/attention/tests/fixtures/declined-proposal/`:

- `people/owen-marsh.md` is tagged `tier: dormant`, same frequency signal as
  the `tier-drift-upward` sibling fixture (5 interactions in the trailing
  90 days -- would fire UPWARD drift on its own).
- `wakeups/2026-07-30-owen-marsh.md` is a prior tier-drift proposal for the
  same `(owen-marsh, active)` pair, `status: dismissed`,
  `dismiss-reason: not-this-signal-type`, `fired-on: 2026-07-30` -- 30 days
  before "today" (2026-08-29), well inside the spec's declined-pairing
  suppression window.
- Per `specs/tier-drift.md`'s declined-pairing suppression rule, the
  detector must NOT re-propose the same `(owen-marsh, active)` pair, so
  running the detector against this store must produce **zero** new
  `wakeups/*.md` files, and must leave the existing dismissed wake-up and
  `people/owen-marsh.md` completely untouched.

## Graders

1. `01-silence.py` -- the worked store's `wakeups/` contains exactly the
   one pre-existing file (`2026-07-30-owen-marsh.md`), byte-identical to
   the fixture, and nothing else.
2. `02-people-untouched.py` -- `people/owen-marsh.md` in the worked store
   is byte-identical to the fixture's copy.
