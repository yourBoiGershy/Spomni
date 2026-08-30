# Expected outcome: warrant-ordering (review-tiers Step 3)

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`. Grading is entirely by the deterministic Python grader
in `graders/`, which checks the one file this prompt writes —
`data-ingestion/review-judgments/2026-08-29.jsonl` — against hand-derived
**pairwise `attention_warrant` orderings**, not a byte-diffable golden
store or exact warrant values. Same reasoning as
`packages/ingestion/evals/cases/kind-classification-corpus/expected/
README.md` and `packages/ingestion/evals/cases/triage-held-respected/
expected/README.md`: the exact integer a judge assigns is model judgment,
but the *relative ranking* between two people is fixture-mandated once
kind, evidence, and the confirmed user model's axis weights are fixed.

## `store` is the shared sibling corpus

This case's `store` frontmatter points directly at
`packages/ingestion/evals/cases/kind-classification-corpus/before` — it
carries no `before/` of its own. Per that directory's own
`expected/README.md`, it is deliberately built to be reused, byte-for-
byte, by `warrant-ordering` (this case) and `de-saturation`, all three
grading different angles of the same 12-person corpus. Any change to that
shared `before/` is a change to all three cases.

## Why `model: sonnet`, not the harness default (`haiku`)

Per-case override of `eval-suite.sh`'s haiku default
(`packages/core/contracts/eval-case.md`'s `model` field docs) — haiku
already failed `relationship-scoring.md`'s batched 12-person rationale
contract on the sibling `kind-classification-corpus` case (see that
case's `expected/README.md` note and completion report for the exact
FAIL/RESULT lines). This case reuses the same Step-3 judge prompt over
the same 12-person batch, so it inherits the same haiku-fails-the-batch
risk; `model: sonnet` is applied here from the start rather than
discovered by a failed haiku attempt.

## Hand-derived pairwise ordering expectations

All four evidence fields cited below come from `before/data-ingestion/
evidence.jsonl`; kind/tier/`kind_source` come from `before/people/
<slug>.md`; axis weights and protected time come from `before/
user-model.md`; kind priors come from `before/data-ingestion/
ranking-weights.json`.

| pair | why the left side must outrank the right |
|---|---|
| `mara-quill` > `pip-larkin` | mara-quill: stated (sticky) `friend`, touchpoints=7, meetings=7, standing monthly dinner, protected under the confirmed user-model's `friends: 0.70` axis ("Protected time" section explicitly names the weekly-friends dinner), `kinds.friend` prior 1.3 (emphasize). pip-larkin: `kind_expires: 2026-08-20`, already past "today" (2026-08-29) — the expired-kind rule (`relationship-scoring.md` `## Rules`) forces `attention_warrant: 0` regardless of the judge's kind call this pass. |
| `ravi-sundar` > `pip-larkin` | ravi-sundar: stated (sticky) `friend`, touchpoints=11 (highest in the corpus), meetings=2, chat_days=6, near-weekly book trades, tier already `inner-circle`. pip-larkin: rule-forced to 0 (see above). |
| `ines-castellano` > `bram-fiske` | ines-castellano: touchpoints=8, meetings=3, co_attended=1, an upcoming 2026-09-03 sync, `kind: collaborator` (`kinds.collaborator` prior 1.2, emphasize) — active, engaged, ongoing work. bram-fiske: touchpoints=2 (at, not below, the insufficient-data gate), median_gap_days=93, days_since_last=23, `kind: transactional` (no prior entry, floats at the 1.0 default) — sparse, low-engagement, arm's-length. |
| `mara-quill` > `hal-torrance` | mara-quill: see above, warm/active/protected-axis friend. hal-torrance: touchpoints=2 (at the gate boundary), days_since_last=41, `kind: professional`, "occasional check-ins" — thin, low-frequency, work-only, no emphasis prior. |

In addition to the four orderings above, two rule-consistent checks
replace the ordering leg described below:

| check | why |
|---|---|
| `pip-larkin` `attention_warrant` == 0 | exact-value, rule-bound — see "Why pip-larkin is graded as 0". |
| `dex-morrow` `attention_warrant` <= 25 | ceiling, not exact — dex-morrow is a cold, zero-reply pitch (touchpoints=3, `user_initiated_share=0`), kind-capped at `active` and de-emphasized (`kinds.unsolicited` prior 0.5); no plausible reading lands it high, but the exact value is model judgment, so 25 is a generous ceiling rather than an exact match. |

## Why pip-larkin is graded as 0

The case's original brief asked for a chain — "a real friend outranks a
daily scheduling contact which outranks an unanswered pitch" — i.e.
`mara-quill` > `pip-larkin` > `dex-morrow`. That `pip-larkin` >
`dex-morrow` leg was a mistake in the brief: pip-larkin's already-stored
`kind_expires` (`2026-08-20`) is in the past relative to "today"
(`2026-08-29`) in this shared fixture, and `relationship-scoring.md`'s
expired-kind rule is unconditional — "a `kind_expires` in the past forces
`attention_warrant: 0`... this applies whether the expired `kind_expires`
is the person's already-stored value... or one this judgment pass itself
would otherwise propose." A rule-compliant judge cannot output anything
for pip-larkin other than `attention_warrant: 0`, no matter which `kind`
it assigns this pass (`scheduling` or `transactional`, both in the
sibling case's acceptable set) — so pip-larkin's warrant is graded as an
**exact value (0)**, not part of an ordering, and dex-morrow is graded
independently against a ceiling instead of being compared to pip-larkin.
Confirmed live: three `eval-run-skill.sh` runs against the original
ordering-leg grader all failed identically on this exact pattern (pip-
larkin at 0, dex-morrow reasonably non-zero, every other leg PASS) — see
the completion report for the exact RESULT lines from both the original
grader and this corrected one.

## Graders

1. `01-pairwise-order.py` — record count/shape (12 records), the four
   pairwise `attention_warrant` ordering checks from the table above, the
   `pip-larkin == 0` exact-value check, and the `dex-morrow <= 25` ceiling
   check, printing PASS/FAIL per check.
