# Expected outcome: multi-person debrief filed against both participants

This case's `graders/` derive their assertions directly from the fixture
(`packages/ingestion/tests/goldens/debrief/03-multi-person-meeting/before`)
and the capture event embedded in `prompt.md`, checking specific
frontmatter values and content-word facts on the worked store — rather
than a byte-diffable `expected/` tree. A live skill run's prose (summary
wording, exact fact phrasing) isn't guaranteed identical to a hand-authored
golden even when the filing is substantively correct, so a full-tree
byte-diff is too brittle here (same reasoning as
`packages/ingestion/evals/cases/confirm-first-tier-writes/expected/
README.md` and `packages/attention/evals/cases/zero-create-without-
confirm/expected/README.md`). This directory exists only to satisfy the
`expected` frontmatter field the T3 runner (`eval-run-skill.sh`) requires;
it is not consumed by `RA_GRADER_DIFF`.

The hand-authored golden this case's fixture was drawn from —
`packages/ingestion/tests/goldens/debrief/03-multi-person-meeting/
expected/` — remains the canonical byte-level reference for what a fully
correct filing pass produces; this case's graders check the subset of that
golden's facts that matter for grading a live, non-deterministic run.

## Graders

1. `01-interaction-file-and-last-touch.py` — exact-value checks: the
   interaction file lands at `interactions/2026-08-29-nadia-okafor.md`
   (Nadia primary, per SKILL.md §5b) with correct `schema_version`, `date`,
   both people linked, `calendar-event: null`, and the right
   `source-capture` id; both `nadia-okafor.md` and `sam-vartan.md` get
   `last-touch: 2026-08-29`.
2. `02-facts-and-commitment.py` — content-word checks: Nadia's promotion to
   Director of Operations is recorded (frontmatter `role` or a `## Facts`
   bullet), Sam's house-closing is a `## Facts` bullet, and a dinner-spot
   commitment from Nadia is recorded somewhere (interaction `##
   Commitments` or a person `## Open threads` cross-reference).
