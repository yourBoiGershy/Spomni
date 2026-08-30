# Expected outcome: the triage-held ledger is respected in batch mode

This case's `graders/` derive their assertions directly from the fixture
and `prompt.md` (file-existence and ledger-content checks on specific
`data-ingestion/*.log`, `interactions/*.md`, and `people/*.md` files),
rather than a byte-diffable `expected/` store — a live skill run's
untouched-file bytes (whitespace, section ordering, prose phrasing in the
one file that IS supposed to change) aren't guaranteed identical to a
hand-authored golden even when every field under test is correct, so a
full-tree byte-diff would be too brittle here (same reasoning as
`packages/ingestion/evals/cases/confirm-first-tier-writes/expected/
README.md`). This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

## Why this case exists

Triage itself (`packages/ingestion/scripts/triage-inbox.sh`) is
deterministic and already regression-locked by
`packages/ingestion/tests/run-triage-tests.sh` (plan 26 U10) — not worth
an eval. The one *model*-facing behavior worth eval-guarding is the batch-
mode exclusion this plan wrote into `packages/ingestion/skills/debrief/
SKILL.md` §1: does the debrief skill actually honor
`data/ingestion/triage-held.log` when it sweeps `inbox/` for unfiled
events, the same way it already honors `data/ingestion/debrief-filed.log`?

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`./store/inbox/` has exactly three capture events:

| Event id | Ledger state | Expected outcome |
|---|---|---|
| `triage-held-fixture-held` | in `triage-held.log` (noreply-marketing) | ZERO writes: no `debrief-filed.log` entry, no interaction, no new person file |
| `triage-held-fixture-filed` | in `debrief-filed.log` already | Untouched: exactly one `debrief-filed.log` entry (no duplicate), its pre-existing interaction (`interactions/2026-08-01-sam-quill.md`) and `people/sam-quill.md` byte-identical to the fixture |
| `triage-held-fixture-eligible` | in neither ledger | Filed normally: new `debrief-filed.log` entry, `interactions/2026-08-20-morgan-alvarez.md` created with `source-capture: triage-held-fixture-eligible` and a `[[morgan-alvarez]]` link, `people/morgan-alvarez.md` gains a new fact |

Per SKILL.md §1's batch-mode sweep (quoted verbatim in `prompt.md`): "every
capture event whose `id` is **not** in `data/ingestion/debrief-filed.log`
and **not** in `data/ingestion/triage-held.log`" — held and filed events
are both excluded from the sweep entirely; only the eligible event is
processed.

## Graders

1. `01-held-event-zero-writes.py` — the held event produces literally
   nothing: not filed, no interaction traceable to it, no new person file
   at all (this fixture's held event mentions no resolvable person, so any
   third `people/*.md` file is itself a violation).
2. `02-filed-event-untouched.py` — the already-filed event is not
   re-processed: `debrief-filed.log` has exactly one entry for it (not
   two), and both its pre-existing interaction and person file are
   byte-identical to the fixture (no re-write).
3. `03-eligible-event-filed.py` — the one event actually eligible for this
   pass is filed: new ledger entry, new interaction with the right
   `source-capture`/people link, and the person file was actually updated
   (not byte-identical to its original — this eval doesn't grade exact
   prose, only that filing actually happened, per fact-based grading).

## Manual verification performed

All three graders were run directly against hand-built worked-store copies
of this fixture (the correct three-way outcome, and doctored variants that
flip each invariant) — see the completion report for the exact commands
and PASS/FAIL output, and for the live `eval-suite.sh` run's result line.
