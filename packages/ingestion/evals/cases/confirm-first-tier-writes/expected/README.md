# Expected outcome: exactly two tier writes, both explicitly confirmed

This case's `graders/` derive their assertions directly from the fixture
and the prompt's simulated conversation (frontmatter checks on specific
`people/*.md` files), rather than a byte-diffable `expected/` store — a
live skill run's untouched-file bytes (whitespace, section ordering
elsewhere in a file) aren't guaranteed identical to a hand-authored golden
even when the one field under test is correct, so a full-tree byte-diff
would be too brittle here (same reasoning as
`packages/attention/evals/cases/zero-create-without-confirm/expected/README.md`).
This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`.

## Hand-derived expected outcome (from `prompt.md`'s simulated conversation)

Per `prompt.md`'s Step-6 scenario — four presented people, four different
outcomes:

| Person | Suggested | User's reply | Expected end state |
|---|---|---|---|
| `hana-oduya` | `close` | "confirm" | `tier: close` |
| `victor-lang` | `active` | "adjust to inner-circle" | `tier: inner-circle` |
| `priya-sethi` | `dormant` | "skip" | no `tier` key at all |
| `omar-fitch` | `active` | (session ended, never reached) | no `tier` key at all |

Per `packages/ingestion/skills/onboarding-seed/SKILL.md`'s Step 6 ("Only on
explicit per-person confirmation... file the tier... A skip writes
nothing... Ending the session mid-batch is treated as a skip for everyone
not yet acted on") and
`packages/ingestion/specs/stated-preference-filing.md` (a).2 (the
unambiguous existing-person frontmatter `tier` overwrite), the correct
outcome is exactly the two writes in the table above — nothing else in
`people/` changes, and no other file anywhere in the store is touched.

## Graders

1. `01-confirm-adjust-written-correctly.py` — `hana-oduya.md` and
   `victor-lang.md` land exactly `tier: close` and `tier: inner-circle`
   respectively (not merely non-empty — the exact value the user actually
   named).
2. `02-skip-and-undecided-untouched.py` — plan 24's confirm-first
   invariant as code: `priya-sethi.md` and `omar-fitch.md` have no `tier`
   key, AND — scanning every `people/*.md` file in the worked store, not
   just the two named above — any tier value on a person with no
   confirmation utterance in the conversation is a FAIL regardless of
   which file it lands on (catches a hallucinated write this case didn't
   even name).

## Manual verification performed

Both graders were run directly against hand-built worked-store copies of
this fixture (the correct four-way outcome, and a doctored variant with a
tier pre-written on the skipped person) — see the completion report for
the exact commands and PASS/FAIL output, and for the live
`eval-suite.sh` run's result line.
