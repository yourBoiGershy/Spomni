# Expected outcome: shard mode confines writes to the shard's own ids

This case's `graders/` derive their assertions directly from the fixture
and `prompt.md` (file-existence and ledger-content checks on specific
`data-ingestion/*.log`, `interactions/*.md`, `people/*.md`, and
`index.json`), rather than a byte-diffable `expected/` store — a live
skill run's untouched-file bytes (whitespace, section ordering, prose
phrasing in the files that ARE supposed to change) aren't guaranteed
identical to a hand-authored golden even when every field under test is
correct, so a full-tree byte-diff would be too brittle here (same
reasoning as `packages/ingestion/evals/cases/triage-held-respected/
expected/README.md`). This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

## Why this case exists

Plan 27 added shard mode to `packages/ingestion/skills/debrief/SKILL.md`
§1, with a single-writer confinement guarantee: a shard worker may only
touch the ids listed in its own shard file, and must never file — or even
read for filing purposes — an eligible event that lands in some other
shard. This is the one *model*-facing behavior worth eval-guarding: the
deterministic shard-assignment itself
(`packages/ingestion/scripts/shard-filing-batch.sh`) is regression-locked
by its own script tests, not this eval; what only a live skill run can
verify is that the debrief skill, invoked in shard mode over one shard
file, actually respects that boundary — filing every id the shard file
names and touching nothing else, with the shard's own per-shard ledger
instead of the main one, and the index left alone.

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`./store/inbox/` has exactly four capture events; `./store/data-ingestion/
shards/shard-1.ids` lists exactly two of them (both naming the same known
person, Dana Kowalski):

| Event id | In shard-1.ids? | Expected outcome |
|---|---|---|
| `shard-fixture-dana-standup` | yes | Filed: new `debrief-filed.shard-1.log` entry, `interactions/2026-08-18-dana-kowalski.md` created with `source-capture: shard-fixture-dana-standup` and a `[[dana-kowalski]]` link |
| `shard-fixture-dana-followup` | yes | Filed: new `debrief-filed.shard-1.log` entry, `interactions/2026-08-19-dana-kowalski.md` created with `source-capture: shard-fixture-dana-followup` and a `[[dana-kowalski]]` link |
| `shard-fixture-alex-checkin` | no | ZERO writes: no ledger entry anywhere, no interaction file, `people/alex-rivera.md` byte-identical to the fixture |
| `shard-fixture-jamie-update` | no | ZERO writes: no ledger entry anywhere, no interaction file, `people/jamie-torres.md` byte-identical to the fixture |

Additionally, per SKILL.md §5c's shard-mode deviation:

- `data-ingestion/debrief-filed.log` (the main ledger) stays byte-identical
  to the fixture — empty, same as it started. Only
  `debrief-filed.shard-1.log` gains the two ids, and it must contain
  *exactly* those two, in order, nothing else.
- `index.json` stays byte-identical to the fixture — no rebuild runs in
  shard mode; that is the wave orchestrator's job, once, after every shard
  worker finishes.

## Graders

1. `01-shard-ids-filed.py` — the two ids listed in `shard-1.ids` are
   filed: an interaction file exists per id (traceable via
   `source-capture`), each with the `[[dana-kowalski]]` link, and
   `debrief-filed.shard-1.log` contains exactly those two ids, nothing
   else.
2. `02-unlisted-ids-untouched.py` — the two ids NOT listed in the shard
   file produce no writes anywhere: no interaction file traceable to
   either, no entry for either id in any ledger (main or per-shard), and
   `people/alex-rivera.md` / `people/jamie-torres.md` byte-identical to
   the fixture.
3. `03-main-ledger-and-index-untouched.py` — the main
   `debrief-filed.log` stays byte-identical (still empty) and
   `index.json` stays byte-identical to the fixture — shard mode never
   touches either.

## Manual verification performed

All three graders were run directly against a hand-built worked-store copy
of this fixture (the correct four-way outcome, and doctored variants that
flip each invariant) — see the completion report for the exact commands
and PASS/FAIL output, and for the live `eval-suite.sh` run's result line.
