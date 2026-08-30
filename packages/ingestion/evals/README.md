# Ingestion evals

These T3 (skill-tier) cases wrap the six existing stated-preference goldens
(`packages/ingestion/tests/goldens/preferences/*`) as executable evals —
each case's `store`/`expected` frontmatter fields point at a golden's
`before/`/`expected/` directories rather than copying them, so the golden
fixtures stay the single source of truth for expected deltas. All six carry
`runnable-when: "03"` and report `SKIP` from `eval-run-skill.sh` until plan
03's filing engine exists; once it lands, drop `runnable-when` from each
case's frontmatter to flip them from SKIP to live, must-pass cases.

## Plan 30 — semantic scoring cases

Nine T3 cases exercising `review-tiers` skill steps (priors, judge, skew
check, write-back) against the plan-30 semantic-scoring/user-model contract
(`packages/core/contracts/relationship-scoring.md`). Grading is by
sets/orderings/properties rather than byte-exact diffs, since LLM judgment
output is non-deterministic:

- `kind-classification-corpus` — proves Step 3 (judge) classifies a batch
  of people into the expected `kind` set from `./store`'s pre-seeded priors.
- `warrant-ordering` — proves judge-produced warrants are internally
  ordered/consistent (not just individually plausible).
- `de-saturation` — smoke; proves scores don't clip/saturate at the rating
  extremes across the batch.
- `user-model-propagation` — proves a user-model revision (`friends: 0.30`
  → rev2) propagates into a second judge pass's output, run twice in one
  session (once per revision).
- `neighbor-prior-consistency` — proves nearest-neighbor priors stay
  consistent with the judged output for people sharing a cluster.
- `no-ollama-fallback` — smoke; proves the skill does not silently fall
  back to a local Ollama model when the configured model is unavailable.
- `rescale-skew-detection` — proves Step 4 (skew check + present) flags a
  pre-seeded skewed `rescale-scores.sh --report` correctly.
- `review-tiers-zero-writes-without-confirm` — smoke; proves no additional
  `people/*.md` writes happen beyond what Steps 1-3 already produced,
  absent a fresh user confirmation.
- `stated-kind-sticks` — smoke; proves the validate-and-write sub-step
  skips people whose current `kind_source: stated-by-user`, per the
  relationship-scoring contract's sticky-kinds rule, even when a judgment
  record targets them.

Model overrides: `kind-classification-corpus`, `warrant-ordering`,
`de-saturation`, and `user-model-propagation` pin `model: sonnet` in their
frontmatter (deliberate per-case override — haiku failed the batched
12-person rationale contract in earlier runs; cost ≈ $0.35-0.45 per run).
The remaining five cases (`neighbor-prior-consistency`,
`no-ollama-fallback`, `rescale-skew-detection`,
`review-tiers-zero-writes-without-confirm`, `stated-kind-sticks`) run at
the suite default `model: haiku` (cost ≈ $0.04-0.23 per run).

`warrant-ordering` and `de-saturation` both point their `store` at
`kind-classification-corpus/before` rather than their own `before/`
directory — they judge the same pre-seeded batch, just grade different
properties of the output (ordering vs. saturation), so there's no separate
fixture to maintain.

Runtime/cost notes for running the full suite: `user-model-propagation`
runs two judgments in a single session and has hit the per-case wall-clock
guard (`RA_EVAL_TIMEOUT_SECS`, default 300) once in practice — set
`RA_EVAL_TIMEOUT_SECS=600` when running the full suite. The suite-wide
`RA_EVAL_MAX_COST_USD` default of 2.00 will be exceeded by the full
28-case run given the four sonnet-tier cases above — raise it (e.g. `export
RA_EVAL_MAX_COST_USD=6.00`) or run smoke-only cases with `RA_EVAL_SMOKE=1`.
