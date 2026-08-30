# Expected outcome: review-tiers judging runs identically without embeddings

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

`review-tiers/SKILL.md`'s "Both Ollama modes" section documents that the
whole judging flow must degrade gracefully — never stall, never error —
when `embed-people.sh`/`cluster-people.sh`/`nearest-confirmed.sh` report
`embeddings: unavailable`: no clustering, every person judged
individually in slug order, and the judgment prompt's neighbor input
becomes the literal `neighbors: none (embeddings unavailable)` line. The
one model-facing behavior worth eval-guarding: does the flow actually run
to completion and still write derived kinds, with the fallback line used
verbatim and no hallucinated neighbor, rather than silently dropping
people or inventing neighbor relationships that don't exist?

This case shares its base store with the `neighbor-prior-consistency`
sibling case (same 5 people, same evidence) — the only difference is the
absence of `neighbors.tsv`/`clusters.tsv` and the presence of
`data-ingestion/run.log` recording `embeddings: unavailable`, proving the
flow's behavior with and without embedding priors from the same starting
point.

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`./store/people/` has the same 5 people as the sibling case: `mara-quill`
(stated `friend`/`close`), `sol-abernathy` and `june-abernathy` (unkinded),
`hal-torrance`/`bram-fiske` (already `derived` kinds). With no
`neighbors.tsv`/`clusters.tsv` and `embeddings: unavailable` recorded in
`run.log`:

| Person | Expected outcome |
|---|---|
| `mara-quill` | judged (record present, `kind: friend` — stated kinds are sticky), `neighbors: none (embeddings unavailable)`; `people/mara-quill.md` untouched |
| `sol-abernathy` | judged individually, `neighbors: none (embeddings unavailable)`, `kind_source: derived`; `kind` in `{friend, unknown, community, professional}` — looser than the sibling case since there's no neighbor prior to narrow it |
| `june-abernathy` | same as sol-abernathy; `kind` in `{family, friend, unknown}` |
| `hal-torrance` / `bram-fiske` | judged individually, `neighbors: none (embeddings unavailable)` |

All 5 people get exactly one judgment record (the flow never stalls or
partially completes on this condition), and none of the 5 records may
name another slug as a "neighbor" — the fallback line is the literal
string, not a paraphrase or an invented neighbor.

## Graders

1. `01-fallback-runs.py` — the judgments file has exactly 5 records; every
   record's `neighbors` field is exactly `none (embeddings unavailable)`;
   no record's `neighbors` field names another slug; `sol-abernathy` and
   `june-abernathy`'s kinds fall within the (looser, un-neighbor-steered)
   plausible sets; both still get `kind_source: derived` written to their
   person files — the derived-kind write path doesn't depend on
   embeddings being available.
2. `02-exemplar-untouched.py` — `people/mara-quill.md` is byte-identical
   to the fixture original, identical invariant and grader to the sibling
   case.

## Manual verification performed

Both graders were run directly against hand-built worked-store copies of
this fixture (the correct outcome, and doctored variants that flip each
invariant) — see the completion report for the exact commands and
PASS/FAIL output, and for the live `eval-run-skill.sh` run's result line.
