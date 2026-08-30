# Expected outcome: confirmed neighbors steer unconfirmed people's kinds

This case's `graders/` derive their assertions directly from the fixture
and `prompt.md` (JSONL-field and frontmatter-field checks on specific
`data-ingestion/review-judgments/2026-08-29.jsonl` and `people/*.md`
files), rather than a byte-diffable `expected/` store — a live judgment
call's prose (`kind_note`, `rationale`) isn't guaranteed identical to a
hand-authored golden even when every field under test is correct, so a
full-tree byte-diff would be too brittle here (same reasoning as
`packages/ingestion/evals/cases/triage-held-respected/expected/README.md`).
This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`.

## Why this case exists

`review-tiers/SKILL.md` Step 3 hands the judgment call a neighbor prior —
"most similar confirmed people: `[[slug]] (<kind>[, <tier>])`" — per
`relationship-scoring.md`'s `## Priors` §3, whenever embeddings are
available. The one model-facing behavior worth eval-guarding here: does an
unconfirmed person actually get steered toward their confirmed neighbor's
kind, rather than the neighbor prior being silently ignored?

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`./store/people/` has 5 people: `mara-quill` (stated `friend`/`close`,
the cluster exemplar), `sol-abernathy` and `june-abernathy` (unkinded
members of mara's cluster, each with `mara-quill` as their sole confirmed
neighbor at similarity 0.93/0.90 per `neighbors.tsv`), and `hal-torrance`/
`bram-fiske` (already `derived` kinds, unrelated singleton clusters, no
neighbor row).

| Person | Cluster role | Neighbor | Expected outcome |
|---|---|---|---|
| `mara-quill` | exemplar, c001 | — | judged (record present, `kind: friend`) but `people/mara-quill.md` untouched — `kind_source: stated-by-user` is sticky |
| `sol-abernathy` | member, c001 | `mara-quill` (friend, close) | `kind_source: derived`, `kind` in `{friend, family}`; judgment record's `neighbors` field names `mara-quill` |
| `june-abernathy` | member, c001 | `mara-quill` (friend, close) | same as sol-abernathy |
| `bram-fiske` | singleton, c002 | none | judged individually; no neighbor steering (not asserted by this case's graders) |
| `hal-torrance` | singleton, c003 | none | judged individually; no neighbor steering (not asserted by this case's graders) |

Per `relationship-scoring.md`'s `## Priors`: "Neighbor priors, when
embeddings are available... e.g. 'most similar confirmed people:
`[[dana]]` (friend, close)'" — the neighbor line is handed to the judgment
verbatim, and the two people whose sole confirmed neighbor is the
`friend`/`close` exemplar should land on a `friend`- or `family`-shaped
derived kind, not an unrelated one like `transactional` or `community`.

## Graders

1. `01-neighbors-steer.py` — `sol-abernathy` and `june-abernathy` end up
   `kind_source: derived` with `kind` in `{friend, family}`, and their
   judgment records' additive `neighbors` field names `mara-quill` — the
   one observable trace that the neighbor prior was actually read, not
   just present in the prompt.
2. `02-exemplar-untouched.py` — `people/mara-quill.md` is byte-identical
   to the fixture original: a `stated-by-user` kind is never rewritten,
   even though mara-quill is read as the cluster exemplar.

## Manual verification performed

Both graders were run directly against hand-built worked-store copies of
this fixture (the correct outcome, and doctored variants that flip each
invariant) — see the completion report for the exact commands and
PASS/FAIL output, and for the live `eval-run-skill.sh` run's result line.
