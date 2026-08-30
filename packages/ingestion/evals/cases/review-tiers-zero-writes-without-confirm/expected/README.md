# Expected outcome: zero tier writes, exactly two logged skips

This case's `graders/` derive their assertions directly from the fixture
and the prompt's simulated conversation (byte-compare on `people/*.md`
against `before/`, plus a format/content check on the skip ledger), rather
than a byte-diffable full-tree `expected/` store — a live skill run's
untouched-file bytes elsewhere in the store aren't guaranteed identical to
a hand-authored golden even when the fields under test are correct, so a
full-tree byte-diff would be too brittle here (same reasoning as
`packages/ingestion/evals/cases/confirm-first-tier-writes/expected/
README.md` and `packages/attention/evals/cases/zero-create-without-confirm/
expected/README.md`). This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from `prompt.md`'s simulated conversation)

Per `prompt.md`'s Step-4 scenario — four presented people, zero
confirm/adjust replies:

| Person | Suggested | User's reply | Expected end state |
|---|---|---|---|
| `sol-abernathy` | `close` | "skip" | no `tier` key; skip-ledger line `sol-abernathy\t<ISO 8601 Z>` |
| `june-abernathy` | `active` | "skip" | no `tier` key; skip-ledger line `june-abernathy\t<ISO 8601 Z>` |
| `otto-brandvold` | `active` | (session ended, never reached) | no `tier` key; NO skip-ledger line |
| `hal-torrance` | `dormant` | (session ended, never reached) | no `tier` key; NO skip-ledger line |

Per `packages/ingestion/skills/review-tiers/SKILL.md`'s Step 4 ("Zero tier
writes without confirmation... A skip writes nothing... Skip appends one
line to the skip ledger... Ending the session mid-batch is treated as a
skip for everyone not yet acted on — never logged"):

- No person file may gain a `tier` value — none of the four transcript
  outcomes above is a confirm or an adjust.
- Since this case's Steps 1-3 already ran off-screen (per `prompt.md`) and
  Step 4 alone, given zero confirm/adjust actions, never calls
  `person-set-kind.sh`, every `people/*.md` file (including the three that
  already carry a `derived` `kind` from the off-screen judge step) must
  stay byte-identical to `before/` — not just untiered, untouched
  entirely.
- The skip ledger (`data-ingestion/review-skips.log`, bound to
  `./store/data-ingestion/review-skips.log` for this eval workspace) must
  gain **exactly two** new lines — one for each explicit skip
  (`sol-abernathy`, `june-abernathy`), each `<slug>\t<ISO 8601 Z>` — and
  **zero** lines for `otto-brandvold`/`hal-torrance`, since an unlogged
  session-end is explicitly distinguished from an explicit skip by the
  skill's binding rule.
- No other file anywhere in the store is touched.

## Graders

1. `01-no-tier-writes.py` — every one of the four `people/*.md` files is
   byte-identical to `before/` (not merely "no `tier` key" — the whole
   file, including the already-derived `kind`/`kind_note`/`kind_source`/
   `kind_updated` fields on three of them, since this case's Step 4 has no
   reason to touch any person file when zero confirm/adjust actions
   occurred).
2. `02-skip-ledger.py` — the skip ledger (starting empty in `before/`) has
   exactly two non-empty lines after the run, one each for
   `sol-abernathy`/`june-abernathy` in `<slug>\t<ISO 8601 Z>` form, and no
   line for `otto-brandvold`/`hal-torrance` (session-end is not logged).

## Manual verification performed

Both graders were run directly against hand-built worked-store copies of
this fixture (the correct four-way outcome, and two doctored variants —
one with a tier added to `sol-abernathy.md`, one with a third,
session-end skip line for `otto-brandvold` appended to the ledger) — see
the completion report for the exact commands and PASS/FAIL output, and for
the live `eval-run-skill.sh` run's result line.
