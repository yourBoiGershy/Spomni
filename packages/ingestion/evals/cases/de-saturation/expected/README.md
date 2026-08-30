# Expected outcome: de-saturation guard (review-tiers Step 3)

<!-- prompt.md frontmatter note: `model: sonnet` is a deliberate per-case
     override of eval-suite.sh's haiku default (per eval-case.md's `model`
     field docs), inherited from the sibling `kind-classification-corpus`
     case — haiku failed relationship-scoring.md's rationale contract on
     this same batched 12-person judgment (see that case's
     `expected/README.md` and completion report for the exact FAIL/RESULT
     lines from attempts 1-2). Sonnet is used here without re-trying
     haiku first, since the failure mode is identical (one skill run, one
     batched judgment prompt, same fixture) and re-proving it would just
     burn budget on an already-known result. -->

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`. Grading is entirely by the deterministic Python grader in
`graders/01-no-saturation.py`, which checks the one file this prompt
writes — `data-ingestion/review-judgments/2026-08-29.jsonl` — against
fact-based population-level rules, not a byte-diffable golden store (same
reasoning as the sibling case's `expected/README.md`: kind/tier judgment is
model reasoning, not a pure function of the fixture).

## Why this case exists — the 2026-08-29 live failure

On 2026-08-29 a live `review-tiers` Step-3 run over the user's real store
(23 people) suggested `inner-circle` for 20 of them — the judge let
neighbor-similarity ("most similar confirmed people: ...") and/or the
batched-prompt framing drift the whole population toward the top tier
instead of reasoning per person from that person's own evidence. This case
is the regression guard for that failure, reusing the exact fixture shape
that reproduces the risk: two confirmed exemplars sit at the top of the
tier ladder (`mara-quill` stated `close`, `ravi-sundar` stated
`inner-circle`, both `kind_source: stated-by-user`), and three
low-touchpoint members have one of those exemplars as their nearest
confirmed neighbor per `before/data-ingestion/neighbors.tsv`:

| slug | nearest confirmed neighbor | neighbor kind/tier |
|---|---|---|
| `sol-abernathy` | `mara-quill` | `friend`, `close` |
| `june-abernathy` | `ravi-sundar` | `friend`, `inner-circle` |
| `otto-brandvold` | `ravi-sundar` | `friend`, `inner-circle` |

A judge that treats the neighbor line as a strong pull toward that
neighbor's tier — rather than as one input relationship-scoring.md's
"## Priors" section explicitly subordinates to the evidence-driven rules
("a prior never overrides ... any rule in relationship-scoring.md's
## Rules") — reproduces the live saturation on this smaller fixture.

## `before/` is shared

`store:` points at the sibling `kind-classification-corpus` case's
`before/` directory (byte-for-byte reuse, per that case's own
`expected/README.md`, which lists `de-saturation` as one of two sibling T3
cases sharing it — the other is `warrant-ordering`). This case adds no new
fixture files; it grades the same 12-person corpus, priors, and
neighbor/cluster files from the population-saturation angle. Do not fork or
diverge `before/`'s contents without updating the sibling cases; a change
there is a change to this case's inputs too.

## Hand-derived expectation

Two people in this 12-person fixture are confirmed at the top two tiers
(`mara-quill` — `close`, `ravi-sundar` — `inner-circle`), both via
`kind_source: stated-by-user`, and both `kind: friend`. Nothing else in the
fixture is confirmed at any tier. Reasoning per person from
`evidence.jsonl` alone (touchpoints, gaps, meetings, kind caps, the
insufficient-data gate, and the expired-kind rule — see
`packages/core/contracts/relationship-scoring.md`'s "## Rules") gives no
evidentiary basis for a third person to land at `inner-circle`:

- The three people whose nearest confirmed neighbor is one of those two
  exemplars (`sol-abernathy`, `june-abernathy`, `otto-brandvold`) each have
  their own, much thinner, evidence (5, 3, and 8 touchpoints respectively,
  no meetings, no stated kind) — the neighbor line is context, not a tier
  assignment.
- `pip-larkin`'s `kind_expires: 2026-08-20` is already in the past as of
  today (2026-08-29) — the expired-kind rule zeroes the warrant and nulls
  the tier regardless of the otherwise-high touchpoint count (10).
- `wren-halloway`'s single touchpoint trips the insufficient-data gate —
  `suggested_tier: null`.
- The `scheduling`/`transactional`/`unsolicited`/`unknown` kind caps
  (`bram-fiske`, `dex-morrow`, `hal-torrance`, `pip-larkin` if it keeps
  `kind: scheduling`) block those records from `close`/`inner-circle`
  entirely.

So the correct population shape is: at most 2 records at `inner-circle`
(the two already-confirmed exemplars, or fewer if a judge reasonably
demotes a stated tier's *suggestion* — note the stated `kind` is sticky,
but `suggested_tier` for an already-confirmed person is still the judge's
independent call), the two expired/insufficient-data people forced to
`null`, the kind-capped people held at `active` or below, and the
remaining people spread across `active`/`dormant`/`close` rather than
piled onto one tier.

## Grader

`graders/01-no-saturation.py` — record count/shape (12 records, one per
fixture slug), the population cap (`suggested_tier: inner-circle` on at
most 2 records), kind caps (scheduling/transactional/unsolicited never
above `active`; `unknown` never above `close`), `pip-larkin`'s
expired-kind zero-warrant/null-tier consequence, `wren-halloway`'s
insufficient-data null-tier consequence, and a tier-spread check (at least
3 distinct non-null `suggested_tier` values across the batch — guards
against collapsing to any single tier, not just `inner-circle`).

## Manual verification performed

See the completion report for the exact commands and PASS/FAIL output: the
grader was run directly against a hand-built worked-store copy of this
fixture (a plausible correct, non-saturated 12-record judgment batch), and
against a doctored copy that forces every record to
`suggested_tier: inner-circle` (the exact shape of the live 2026-08-29
failure) to confirm the grader actually bites — plus the live
`eval-run-skill.sh` sonnet run's result line, twice.
