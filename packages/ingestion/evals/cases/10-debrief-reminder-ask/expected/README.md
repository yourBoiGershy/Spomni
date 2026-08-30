# Expected outcome: explicit reminder ask produces a fact + wake-up entry

This case's `graders/` derive their assertions directly from the fixture
(`packages/ingestion/tests/goldens/debrief/04-embedded-reminder-ask/
before`) and the capture event embedded in `prompt.md`, checking specific
frontmatter values and content-word facts on the worked store — rather
than a byte-diffable `expected/` tree. A live skill run's prose isn't
guaranteed identical to a hand-authored golden even when the filing is
substantively correct, so a full-tree byte-diff is too brittle here (same
reasoning as `packages/ingestion/evals/cases/confirm-first-tier-writes/
expected/README.md`). This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

The hand-authored golden this case's fixture was drawn from —
`packages/ingestion/tests/goldens/debrief/04-embedded-reminder-ask/
expected/` — remains the canonical byte-level reference for what a fully
correct filing pass produces; this case's graders check the subset of that
golden's facts that matter for grading a live, non-deterministic run.

## Graders

1. `01-fact-and-last-touch.py` — `marcus-yeun.md` gains a `## Facts`
   bullet mentioning the client pitch, and `last-touch` advances to
   2026-08-29.
2. `02-wakeup-created.py` — exactly one `wakeups/*.md` entry exists, due
   2026-09-19 (2026-08-29 + three weeks), for `marcus-yeun`, with valid
   `wakeup.md` 1.2.0 frontmatter (`status: pending`, `origin: user-ask`,
   non-empty `why`, `## Context` body) — and no spurious extra wake-ups.
