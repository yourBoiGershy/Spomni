# Expected outcome: dismissed cleanly, silently — no second artifact

This case's `graders/` derive their assertions directly from the fixture
(`packages/attention/tests/fixtures/event-confirm/decline-files-silently/`)
and the prompt's decline utterance, rather than from a byte-diffable
`expected/` store — the only substantive difference between the seeded and
worked stores is two frontmatter lines on one file. This directory exists
only to satisfy the `expected` frontmatter field the T3 runner
(`eval-run-skill.sh`) requires; it is not consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from the fixture + prompt)

Per `packages/attention/tests/fixtures/event-confirm/decline-files-silently/`
and this case's `prompt.md`:

- `wakeups/2026-08-31-theo-bramwell.md` is seeded as a `kind:
  event-proposal` card, `status: fired`, `confirmed-on`/`created-event-id`
  both null.
- The prompt's sole user message is an explicit decline: "Nah, let's skip
  it — I already grabbed a coffee with Theo yesterday after the pipeline
  sync, no need for a separate lunch." — closest match in
  `packages/core/contracts/wakeup.md`'s `dismiss-reason` enum
  (`not-now`, `not-this-person`, `not-this-signal-type`,
  `already-handled`) is `already-handled`.
- Per `packages/attention/skills/event-confirm/SKILL.md` step 4 and
  `packages/attention/scripts/wakeup-queue.sh`'s decline semantics, the
  correct outcome is: `status: dismissed`, `dismiss-reason:
  already-handled` (or another enum value clearly justified by the
  utterance), `confirmed-on`/`created-event-id` still null, every other
  field and both prose sections byte-identical to the seed, and no file
  anywhere else in the store touched or created.

## Graders

1. `01-dismissed-correctly.py` — the target wake-up is `status: dismissed`
   with a valid `dismiss-reason` enum value, `confirmed-on`/
   `created-event-id` still null, and every other frontmatter field/line
   (including both prose sections) byte-identical to the seed.
2. `02-no-new-files.py` — plan 21's silent-decline guardrail as code: the
   worked store's file set is exactly the seeded file set (no new file
   anywhere), and every file other than the target wake-up is
   byte-identical to the seed.

## Manual verification performed (no live `claude` run)

Both graders were run directly against hand-built worked-store copies of
this fixture — see the completion report for the PASS/FAIL scenarios
exercised (correct dismiss vs. a hand-built violation that also drops a new
file, and a decline with an invalid `dismiss-reason` value).
