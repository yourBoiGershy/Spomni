---
tier: skill
store: packages/ingestion/evals/cases/feedback-correction-holds/before
expected: packages/ingestion/evals/cases/feedback-correction-holds/expected
max-turns: 12
model: haiku
budget-usd: 0.10
---
Act as the `review-tiers` skill
(`packages/ingestion/skills/review-tiers/SKILL.md`), invoked as
`review tiers --person jane-doe`, running **Step 3 (Judge) only** over
`./store`. Steps 1 and 2 already ran off-screen and produced the
pre-seeded `./store/data-ingestion/evidence.jsonl` (jane-doe's one
`derive-evidence.sh` line) — do not re-derive it, do not run
`derive-user-model.sh`, `embed-people.sh`, `cluster-people.sh`,
`nearest-confirmed.sh`, or `calibrate.sh` yourself. `./store/
user-model.md`, if present, is the confirmed user model. No
`ranking-weights.json` is seeded in this fixture — treat every
`kinds.*`/`evidence.*` prior as its 1.0 default, per
`relationship-scoring.md`'s "absent key defaults to 1.0" rule.

Today is **2026-08-20**.

## Recent corrections (judgment prompt input 2b, verbatim)

## Recent corrections
- 2026-08-20 person:jane-doe — judge said tier=active, user said tier=close, words: "she's basically family"

These are the user's own words about their relationships; a correction
outranks any prior. Do not restate a correction as a rule for other
people unless the words themselves generalize.

## Inputs, in order (per `specs/review-tiers.md`'s judgment prompt
contract)

1. `./store/user-model.md`, verbatim, if present.
2. The priors block above (all defaults, per this fixture).
2b. The recent-corrections block above.
3. For `jane-doe`: `./store/data-ingestion/evidence.jsonl`'s one line,
   `./store/people/jane-doe.md` verbatim, `./store/interactions/*.md`'s
   filed summaries (newest first, max 20 — this fixture has fewer),
   `neighbors: none (embeddings unavailable)`.
4. The rules, verbatim, from `relationship-scoring.md`'s `## Rules` —
   in particular:

> **Stated kinds are sticky:** a `kind_source: stated-by-user` value is
> never overwritten by a judgment record — the classification pass skips
> people whose current kind is user-stated.

> A user correction writes `tier_source: stated-by-user` and sticks —
> never overwritten by a later derived pass.

## Task

Judge `jane-doe` per the contract above, emit exactly one judgment
record (no other text), append it to
`./store/data-ingestion/review-judgments/2026-08-20.jsonl`, then carry
out Step 3's write rules exactly as `SKILL.md` specifies:

- If `jane-doe`'s current `kind_source` is already `stated-by-user`,
  make **no** `person-set-kind.sh` call for them at all — their
  `kind` field stays untouched.
- If `jane-doe`'s current `tier_source` is already `stated-by-user`,
  still attempt the derived tier write via
  `person-set-tier.sh ... --source derived`; when it refuses (exit 2),
  log `tier: kept stated (jane-doe)` and make no further attempt — the
  existing stated tier must be left byte-identical.
- Otherwise, perform the accepted write via `person-set-kind.sh`/
  `person-set-tier.sh --source derived`, exactly as Step 3 specifies.

Write the files now — do not just describe what you would write.
