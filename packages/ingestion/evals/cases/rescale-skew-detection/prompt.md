---
tier: skill
store: packages/ingestion/evals/cases/rescale-skew-detection/before
expected: packages/ingestion/evals/cases/rescale-skew-detection/expected
max-turns: 12
model: haiku
budget-usd: 0.10
---
Act as the `review-tiers` skill
(`packages/ingestion/skills/review-tiers/SKILL.md`), running **Step 4 (skew
check + present) only**, over `./store`. Steps 1 (gate on the user model), 2
(prepare priors), and 3 (judge) already ran off-screen, before this session
started, and produced the following pre-seeded files — do not re-derive
them, do not run `derive-user-model.sh`, `embed-people.sh`,
`cluster-people.sh`, `nearest-confirmed.sh`, `calibrate.sh`, or the judgment
pass yourself, and do not run `rescale-scores.sh` yourself either (its
`--report` output is already pre-seeded below):

- `./store/user-model.md` — the confirmed user model (`revision: 1`).
- `./store/data-ingestion/evidence.jsonl` — one `derive-evidence.sh` line
  per person.
- `./store/data-ingestion/ranking-weights.json` — the seeded `kinds`/
  `evidence` priors.
- `./store/data-ingestion/review-judgments/2026-08-29.jsonl` — Step 3's six
  validated judgment records for today's batch (already passed
  `check-judgment.sh`; nothing here was rejected or retried).
- `./store/data-ingestion/rescale-report.tsv` — the pre-computed
  `rescale-scores.sh <judgments> --report` output for this exact batch (per
  `packages/ingestion/specs/rescale.md`'s `--report` format). Its `overall`
  row reads `skew: yes`.
- `./store/people/*.md` (6 people) and `./store/interactions/*.md` — the
  corpus itself.

Today is **2026-08-29**. The user invoked `review tiers` **without** the
`--rescale` flag.

## Kind → user-model axis mapping (for the breakdown string's priors segment)

`friend` → `friends`; `collaborator` → `business`; `professional` →
`business`; `family` → `family`; `transactional` → `transactional`;
`scheduling` → `business`. Use each axis's weight from `./store/
user-model.md`'s `## Investment mix` (note `friends` is `protected` — see
`## Protected time`), and cite `(rev 1)` for all of them (the user model's
`revision` field).

## SKILL.md's Step 4, quoted verbatim (the operative procedure for this task)

> ```sh
> bash packages/ingestion/scripts/rescale-scores.sh <data-dir>/ingestion/review-judgments/<today>.jsonl --report
> ```
>
> If the overall row reads `skew: yes`, print this warning, exact wording
> (`<reason>` = whichever condition tripped — `share_ge_80 > 0.5`,
> `share_le_20 > 0.5`, or `spread < 10`; `<m>` = the overall mean;
> `<share>` = whichever share triggered it, as a percentage):
>
> ```
> Warrant distribution is skewed (<reason>): mean <m>, <share>% ≥ 80. Re-center with `--rescale`? Suggestions below are shown un-rescaled.
> ```
>
> Only if the user passed `--rescale` at invocation, or answers yes to this
> prompt now, replace the batch: [...] `--rescale` is never auto-applied on
> a skewed batch that the user hasn't explicitly authorized (at invocation
> or in this prompt).
>
> Build each presented person's breakdown string exactly per
> `relationship-scoring.md`'s `## Breakdown string`:
>
> ```
> warrant: <0-100> | kind: <kind> (<kind_source>[, expires <date>]) — <kind_note ≤80c> | evidence: touchpoints=<n> median_gap_days=<n> days_since_last=<n> meetings=<n> chat_days=<n> participation=<v> | priors: user-model.<axis>=<w> (rev <n>[, protected]) kinds.<kind>=<w> evidence.<used keys>=<w> [| neighbors: [[slug]] (<kind>[, <tier>], confirmed) ...] | rationale: <text> | suggested: <tier>
> ```
>
> omitting the `neighbors:` segment entirely when embeddings were
> unavailable for that person (this fixture has no `neighbors.tsv` —
> embeddings were unavailable for this whole batch; omit `neighbors:` for
> every person).
>
> **Present at most 20** records, ordered `attention_warrant` descending,
> then `days_since_last` ascending, then slug ascending — records beyond
> the cap are left untouched exactly like a skip, not queued for later.
> Never frame a low-warrant, dormant, expired, or no-rhythm suggestion as a
> verdict — use the neutral wording above ("scheduling contact — event
> passed"), never "neglected."

This batch is only 6 records, all clear the cap. Compute the overall row's
`share_ge_80` as a percentage for `<share>` in the warning
(`rescale-report.tsv`'s `overall` row: `share_ge_80: 1.00` → `100`).

## Task — do exactly these three things, and nothing else

1. **Print the skew warning.** Write the exact warning text (per the quoted
   template above, with `<reason>`, `<m>`, `<share>` filled in from
   `rescale-report.tsv`'s `overall` row) to
   `./store/data-ingestion/skew-warning.txt` — nothing else in that file.

2. **Present the batch un-rescaled.** Write
   `./store/data-ingestion/presented.jsonl`, one line per presented person,
   each line exactly:

   ```json
   {"slug": "<slug>", "attention_warrant": <int>, "suggested_tier": "<tier>", "breakdown": "<breakdown string>"}
   ```

   Use the **un-rescaled** `attention_warrant` values from
   `review-judgments/2026-08-29.jsonl` (82/85/88/90/95/99) — never the
   `--rescale`d numbers, since `--rescale` was never authorized for this
   run. Order the six lines by `attention_warrant` descending. Every
   breakdown string must follow the exact format quoted above, built from
   this fixture's `evidence.jsonl`, `people/*.md` (`kind_source`,
   `kind_expires`), `ranking-weights.json` (`kinds`/`evidence` weights,
   absent key = `1.0`), `user-model.md` (axis weights, `rev 1`), and each
   judgment record's `kind_note`/`rationale`/`suggested_tier`. Do not append
   a `| rescaled: <from>→<to>` segment to any of them — this batch was never
   rescaled.

3. **Write no tier.** Do not modify any file under `./store/people/` — no
   confirmation or adjustment happened in this session; Step 4 only
   presents.

Write these files now — do not just describe what you would write.
