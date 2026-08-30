# Expected ranking — `packages/attention/fixtures/signals`

Sweep run date: **2026-09-01**. `weekly_tier: normal` (`store/signals/week-plan.json`),
`budget: {"min": 2, "max": 3}`. No pre-existing `origin: signal` wake-ups
due in the plan week → `promotable_count = 3`. No `ranking-weights.json` →
`weight(signal-type) = weight(tag) = 1.0` throughout. Full derivation of
each input in `../README.md`; this file is the final ranked table plus the
held/suppressed disposition, per `packages/attention/specs/ranking.md`
§7–§8.

## Ranked table

| Rank | Signal id | Type | Person(s) | Score | Disposition |
|---|---|---|---|---|---|
| 1 | `20260901T090000Z-co-attendance-walter-combs` | co-attendance | walter-combs, ayesha-malik | 0.765 | **Promoted** → `2026-09-01-walter-combs.md` |
| 2 | `20260901T090000Z-company-news-marcus-chen` | company-news | marcus-chen | 0.611 | **Promoted** → `2026-09-03-marcus-chen.md` |
| 3 | `20260901T090000Z-job-change-marcus-chen` | job-change | marcus-chen | 0.535 | **Promoted** → `2026-09-15-marcus-chen.md` |
| 4 | `20260901T090000Z-birthday-ben-whitmore` | birthday | ben-whitmore | 0.399 | **HELD** — score ≥ 0.15 but below the budget-3 line; re-ranked next sweep, signal event stands in `wakeups/signals/` |
| 5 | `20260901T090000Z-linkedin-post-aiko-tanaka` | linkedin-post | aiko-tanaka | 0.067 | **SUPPRESSED** — score < 0.15 floor (`suppressed: floor` in scan log); also a lone low-confidence signal, which never self-promotes regardless of score |

## Score arithmetic (per `ranking.md` §1–§6; inputs from `store/stats.json`)

```
co-attendance (primary: walter-combs, inner-circle):
  W  = tier(1.0) × recency(1.0, d=1) × density(0.7, touchpoints=1) = 0.700
  W' = 0.5 + 0.5 × 0.700 = 0.850                          (normal week)
  Score = 0.850 × R(0.9) × C(1.0, high) = 0.765

company-news (marcus-chen, active):
  W  = tier(0.65) × recency(1.0, d=17) × density(0.7, touchpoints=2) = 0.455
  W' = 0.5 + 0.5 × 0.455 = 0.7275
  base = 0.7275 × R(0.8) × C(0.7, medium) = 0.4074
  two-signal boost (paired with job-change, both detected_at 2026-09-01,
  within 14 days): 0.4074 × 1.5 = 0.6111 -> 0.611

job-change (marcus-chen, active):
  W' = 0.7275                                              (same as above)
  base = 0.7275 × R(0.7) × C(0.7, medium) = 0.356475
  two-signal boost: 0.356475 × 1.5 = 0.5347125 -> 0.535

birthday (ben-whitmore, close):
  W  = tier(0.85) × recency(1.0, d=17) × density(0.7, touchpoints=1) = 0.595
  W' = 0.5 + 0.5 × 0.595 = 0.7975
  Score = 0.7975 × R(0.5) × C(1.0, high) = 0.399

linkedin-post (aiko-tanaka, dormant):
  W  = tier(0.4) × recency(0.4, d=229) × density(0.7, touchpoints=1) = 0.112
  W' = 0.5 + 0.5 × 0.112 = 0.556
  Score = 0.556 × R(0.3) × C(0.4, low) = 0.06672 -> 0.067
```

## Budget accounting

`promotable_count = budget.max(3) − existing-signal-wakeups(0) = 3`.
Non-suppressed candidates ranked descending: co-attendance (0.765),
company-news (0.611), job-change (0.535), birthday (0.399) — top 3 promoted
(co-attendance, company-news, job-change), birthday held at rank 4.
linkedin-post never enters the budget line at all — it is suppressed by
the floor before ranking against the budget.

## Files this table maps to

- `expected/signal-events/*.md` — all 5 signals (promoted, held, and
  suppressed alike; the signal log is append-only and never drops an
  entry).
- `expected/wakeups/*.md` — exactly 3 files, one per promoted signal:
  `2026-09-01-walter-combs.md`, `2026-09-03-marcus-chen.md`,
  `2026-09-15-marcus-chen.md`.
