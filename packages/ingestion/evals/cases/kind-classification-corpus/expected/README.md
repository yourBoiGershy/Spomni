# Expected outcome: kind-classification corpus judgment (review-tiers Step 3)

<!-- prompt.md frontmatter note: `model: sonnet` is a deliberate per-case
     override of eval-suite.sh's haiku default (per eval-case.md's `model`
     field docs) — haiku failed relationship-scoring.md's rationale
     contract on this batched 12-person judgment (attempts 1-2, see the
     completion report for the exact FAIL/RESULT lines); sonnet is tried
     here before falling back to `xfail`. -->

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`. Grading is entirely by the deterministic Python graders
in `graders/`, which check the one file this prompt writes —
`data-ingestion/review-judgments/2026-08-29.jsonl` — against fact-based
rules and acceptable-value SETS, not a byte-diffable golden store. Kind
classification is model judgment, not a pure function of the fixture, so a
byte-diff golden would fail any reasonable judge that lands on a
defensible-but-different phrasing or an equally-defensible alternate kind
(collaborator vs. professional, for instance) — the same reasoning as
`packages/ingestion/evals/cases/triage-held-respected/expected/README.md`.

## `before/` is shared

`before/` is deliberately built to be reused, byte-for-byte, as the
`store:` fixture for two sibling T3 cases in this same directory:
`warrant-ordering` and `de-saturation`. All three exercise the same 12-
person corpus (`packages/ingestion/tests/fixtures/scoring/store/`'s
people/interactions, `user-model.confirmed.md`, and hand-authored
`ranking-weights.json`/`neighbors.tsv`/`clusters.tsv` priors) from
different angles — this case grades the kind/tier judgment records
themselves; the siblings grade batch-presentation ordering and warrant
rescale/de-saturation behavior over the same inputs. Do not fork or
diverge `before/`'s contents without updating all three cases; a change
here is a change to the shared corpus.

## Why set-grading, not exact-value grading

`packages/core/scripts/eval-case.md`'s golden-tests-before-prompts rule
requires every grader's expected value to be hand-derived from the
fixture — but kind classification asks a model "what kind of relationship
is this?", and more than one kind is a legitimate, defensible read of
several of these people (an accountant is reasonably `transactional` or
`professional`; a low-frequency former client is reasonably
`professional`, `collaborator`, or even `unknown` given how thin the
evidence is). Grading to one exact value would fail a correct judgment for
picking the "other" defensible option, and would silently reward a judge
that happens to match the fixture author's arbitrary first choice — not a
real signal. `01-kind-sets.py` instead grades against a hand-derived
**acceptable set** per person (never copied from a run's own output), and
reserves exact-value grading (`02-record-shape.py`) for the parts of the
judgment record that ARE rule-bound: vocabulary membership, the
insufficient-data gate, kind caps, expired-kind zeroing, and stated-kind
stickiness.

## Hand-derived expectation table

| slug | acceptable `kind` | notes |
|---|---|---|
| `bram-fiske` | `transactional`, `professional` | accountant; billing/filings only; touchpoints=2 (at, not below, the gate) |
| `dex-morrow` | `unsolicited`, `unknown` | cold pitch emails, zero replies |
| `hal-torrance` | `professional`, `collaborator`, `unknown` | former client, low-frequency, thin evidence |
| `ines-castellano` | `collaborator`, `professional` | weekly launch-plan syncs, work-only |
| `june-abernathy` | any (ungraded set; shape rules still apply) | family chat cadence |
| `mara-quill` | `friend` (exact — sticky, `kind_source: stated-by-user`) | tier already `close`, stated |
| `nell-ashby` | any (ungraded set; shape rules still apply) | already `community`, derived |
| `otto-brandvold` | any (ungraded set; shape rules still apply) | quiet group-chat presence |
| `pip-larkin` | `scheduling`, `transactional` | Aug 18 handoff already passed as of "today" (2026-08-29); `kind_expires: 2026-08-20` already stored |
| `ravi-sundar` | `friend` (exact — sticky, `kind_source: stated-by-user`) | tier already `inner-circle`, stated |
| `sol-abernathy` | any (ungraded set; shape rules still apply) | casual, low-intensity chat contact |
| `wren-halloway` | `unknown` (exact — insufficient-data gate consequence) | touchpoints=1 < 2; `suggested_tier` must be `null` |

People not listed with a specific acceptable set in `01-kind-sets.py`
(`june-abernathy`, `nell-ashby`, `otto-brandvold`, `sol-abernathy`) are
still required to exist as one record each and satisfy every rule in
`02-record-shape.py` — they are simply not constrained to a specific kind
set, since the fixture doesn't make any one kind uniquely defensible for
them beyond "not a warm relationship kind with zero supporting evidence"
(a call this case doesn't attempt to pin down further).

## Rule-bound expectations (exact, from `relationship-scoring.md`'s `## Rules`)

- `wren-halloway`: `touchpoints=1 < 2` → insufficient-data gate →
  `suggested_tier: null`, and since no kind was already stated, `kind:
  unknown`.
- `mara-quill`, `ravi-sundar`: `kind_source: stated-by-user`, kind already
  `friend` → sticky rule → record's `kind` must be `friend`, unchanged.
- `pip-larkin`: `kind_expires: 2026-08-20` is already in the past relative
  to "today" (2026-08-29) in the pre-seeded fixture. Any record that keeps
  a past `kind_expires` (whether it keeps `kind: scheduling` or proposes
  another) must zero the warrant (`attention_warrant: 0`) and null the
  tier (`suggested_tier: null`) per the expired-kind rule.
- Any record with `kind: scheduling` must carry a non-null `kind_expires`
  (scheduling-needs-expiry rule).
- `scheduling`/`transactional`/`unsolicited` kinds never suggest above
  `active`; `unknown` never suggests above `close` (kind caps).

## Graders

1. `01-kind-sets.py` — record count/shape (12 records, one per fixture
   slug, no duplicates/missing/extra), the acceptable-`kind`-set checks
   from the table above, and `wren-halloway`'s `suggested_tier: null`.
2. `02-record-shape.py` — vocabulary membership, non-empty `kind_note`,
   `attention_warrant` int in [0, 100], `confidence` enum, `rationale` ≤ 2
   sentences naming the kind and citing ≥1 evidence field by name,
   scheduling-requires-expiry, kind caps, the expired-kind
   zero-warrant/null-tier rule, and the two stated-kind stickiness checks.

## Manual verification performed

Both graders were run directly against a hand-built worked-store copy of
this fixture (a plausible correct 12-record judgment batch), and against
doctored variants that flip each invariant (`pip-larkin` set to `kind:
friend`; a rationale stripped of any evidence-field word) to confirm both
graders actually bite — see the completion report for the exact commands
and PASS/FAIL output, and for the live `eval-run-skill.sh` haiku run's
result line.
