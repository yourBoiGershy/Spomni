# Spec: signal ranking

Package: `attention` (plan 05, amended by plan 12's capacity-mode inversion).
Governs how `wakeups/signals/<id>.md` candidates become ordered, scored,
promoted, held, or suppressed by the sweep's ranking step. Detector-specific
rules (confidence rubrics, timing details, opt-out/dedup mechanics per
signal-type) live in each detector's own spec (e.g.
`packages/attention/specs/scheduling-intent.md`) and are cited here, not
restated. This spec is the single source of truth for the score formula, the
capacity-mode inversion, the two-signal boost, the suppression floor, and the
budget/hold decision — every other doc in `packages/attention` that mentions
ranking should cite this file rather than duplicate its numbers.

## Inputs

Per candidate signal event (one ranking pass per sweep run):

| Source | Fields used |
|---|---|
| `wakeups/signals/<id>.md` (`signal-event@1`) | `type`, `person`, `confidence`, `evidence`, `detected_at` |
| `<store>/stats.json` `people.<slug>` (`derived-index.md`) | `tier`, `touchpoints`, `last_interaction`, `median_gap_days` |
| `<store>/people/<slug>.md` | `tags` |
| `<store>/ranking-weights.json` (`ranking-weights.md`) | `weights.signal-types.<type>.weight`, `weights.tags.<tag>.weight` — absent key defaults to `1.0` |
| `<store>/signals/week-plan.json` (`week-plan.md`) | `weekly_tier`, `budget`, `generated_at` (staleness) |

All dates/times are evaluated relative to the sweep's run date ("today").

## 1. Warmth W (0–1)

`W = tier × recency × density`, each factor from `stats.json`:

| tier | value |
|---|---|
| `inner-circle` | 1.0 |
| `close` | 0.85 |
| `active` | 0.65 |
| `dormant` | 0.4 |
| `null` (unset) | 0.5 |

| recency (days `d` since `last_interaction`) | value |
|---|---|
| `d ≤ 30` | 1.0 |
| `d ≤ 90` | 0.8 |
| `d ≤ 180` | 0.6 |
| `d > 180` or `last_interaction` null | 0.4 |

| density (`touchpoints`) | value |
|---|---|
| `≥ 10` | 1.0 |
| `4–9` | 0.85 |
| `1–3` | 0.7 |
| `0` | 0.5 |

## 2. Capacity-mode warmth W′ (plan 12 inversion)

Read `week-plan.json`'s `weekly_tier` (see budget rule §8 for the
missing/stale fallback). W′ inverts the warmth signal in `open` weeks so
dormant/long-silent ties surface instead of only the already-strong ones:

| `weekly_tier` | W′ formula | Intuition |
|---|---|---|
| `busy` | `W′ = W` | Strong/frequent ties only — low-effort, high-confidence nudges |
| `normal` | `W′ = 0.5 + 0.5·W` | Flattened toward the middle — standard mix |
| `open` | `W′ = (1 − W) + S`, capped at `1.0` | Dormant/long-silent ties rank up; reactivation drafts allowed |

Silence bonus `S` (only applies under `open`), by days since `last_interaction`:

| `d` | `S` |
|---|---|
| `> 180` | 0.5 |
| `> 90` (and `≤ 180`) | 0.25 |
| otherwise | 0 |

`W′` is clamped to a maximum of `1.0` after adding `S` — it is never allowed
to exceed 1 even when `(1 − W)` is already high and `S` is nonzero.

## 3. Rarity R

Fixed per signal `type`, independent of `ranking-weights.json` (rarity is a
structural property of the signal type, not a calibrated preference):

| `type` | R |
|---|---|
| `debrief-harvest` | 1.0 |
| `scheduling-intent` | 1.0 |
| `co-attendance` | 0.9 |
| `company-news` | 0.8 |
| `job-change` | 0.7 |
| `tier-drift` | 0.6 |
| `birthday` | 0.5 |
| `linkedin-post` | 0.3 |

## 4. Confidence C

From the signal event's `confidence` field:

| `confidence` | C |
|---|---|
| `high` | 1.0 |
| `medium` | 0.7 |
| `low` | 0.4 |

## 5. Score

```
Score = W′ × R × C × weight(signal-type) × max(weight(tag) for tag in person.tags)
```

- `weight(signal-type)` = `ranking-weights.json` `weights.signal-types.<type>.weight`, or `1.0` if absent.
- `weight(tag)` = the **maximum** across the person's `tags` list of
  `weights.tags.<tag>.weight` (each falling back to `1.0` when the tag has no
  entry); a person with no tags, or none with an entry, uses `1.0`.
- Round the final score to 3 decimal places.

## 6. Two-signal rule

If a person has **≥ 2 signal events of different `type`** with `detected_at`
within the trailing 14 days:

- Every one of those signal events' scores is multiplied by `1.5` (applied
  after §5's base score, before rounding).
- The resulting promoted wake-up's `## Context` opens with:
  `Priority: high (two independent signals: <type-a>, <type-b>)`.
- A single `low`-confidence signal is never promoted on its own, even if the
  ×1.5 boost would otherwise push it above the suppression floor — the boost
  only applies when a *different-type* companion signal exists; it does not
  let a lone low-confidence signal self-promote.

## 7. Suppression floor

`Score < 0.15` → suppressed. The signal event is still written to
`wakeups/signals/` (append-only, per `signal-event.md`), but it is never
promoted, and the scan log records `suppressed: floor` for it. Suppression is
permanent for that scan pass only — the same signal (or a later one for the
same person) is re-scored fresh on the next sweep as inputs change (e.g.
`last_interaction` moves, a companion signal arrives and the two-signal boost
applies).

## 8. Budget & hold (plan 12)

1. Read `signals/week-plan.json`. If missing, or `generated_at` is more than
   8 days old (`week-plan.md`'s staleness rule), treat `weekly_tier` as
   `normal` with `budget.max = 3` and log the fallback.
2. `promotable_count = budget.max − (count of existing wake-ups with
   origin: signal and status in {pending, fired} whose due date falls in
   [week_start, week_start + 6])`. If negative, treat as `0`.
3. Rank all non-suppressed candidates (post two-signal boost) by score,
   descending. Promote the top `promotable_count`; every candidate below that
   line is **HELD**, not dropped — the signal event persists in
   `wakeups/signals/` and is re-ranked on the next sweep with fresh inputs
   (possibly a fresh score, a fresh budget, or a two-signal boost that wasn't
   available yet).
4. `origin: user-ask` wake-ups never count against `promotable_count` and are
   never subject to this hold/promote ranking at all (`week-plan.md`'s
   exemption rule) — they are out of scope for this spec's ranking pass.

### Hold / suppress / promote decision table

| Condition | Outcome |
|---|---|
| `score < 0.15` | Suppressed (`suppressed: floor` in scan log); signal event stands, never promoted this pass |
| `score ≥ 0.15`, within top `promotable_count` by score | Promoted to `wakeups/<id>.md` |
| `score ≥ 0.15`, below the budget line | Held; re-ranked next sweep |
| Lone `low`-confidence signal, no different-type companion within 14 days | Never promoted, regardless of score |
| `origin: user-ask` | Exempt from budget/ranking entirely; always promoted per its own gate (see the originating detector spec) |

## 9. Pre-ranking gates (applied at the detector, before scoring)

These run in the detector, upstream of this spec's scoring — a signal event
that never reaches the ranking step is not scored at all:

| Gate | Effect |
|---|---|
| `data/store/profile.md` `## Signal opt-outs`: `<type> — all` | No signal event emitted for that type, sweep-wide |
| `## Signal opt-outs`: `<type> — [[slug]]` | No signal event emitted for that type/person pair |
| Dedup: a signal event of the same `type` + `person` was already emitted within the trailing 30 days | Don't re-emit |
| Feedback: a wake-up for the same person was dismissed within the trailing 90 days with `dismiss-reason: not-this-signal-type` (matching `type`) or `not-this-person` | Signal event is still emitted, but marked held-feedback — never promoted this pass |

Detector-specific variants of these gates (e.g. scheduling-intent's
unconditional signal-event emission before its opt-out check) are documented
in the detector's own spec; this table states the general shape all
detectors share.

## 10. Timing (due date) by type

| `type` | `due` |
|---|---|
| `birthday` | The day before the birthday |
| `job-change` | `detected_at` + 14 days (deliberately late — crowd-visible signal, no urgency) |
| `company-news` | `detected_at` + 2 days |
| `co-attendance` | The day after the shared event (or `detected_at` + 1 day if the event has already passed) |
| `debrief-harvest` | Commitment's `by` date − 2 days, else `detected_at` + 3 days |
| `linkedin-post` | `detected_at` + 1 day |
| `scheduling-intent` | `detected_at` + 1–2 days, per `packages/attention/specs/scheduling-intent.md`'s slot-selection rules |
| `tier-drift` | `detected_at` + 1 day |

## 11. Ammunition

Every promoted wake-up's `## Context` section is built from:

1. The trigger line (what fired, in one sentence).
2. Evidence, quoted from the signal event's `evidence` field, labeled by
   provenance per `CLAUDE.md`'s labeling principle: `[inferred-from-email]`,
   `[inferred-from-web]`, or `[stated-by-user]` as appropriate to the source.
3. What the user already knows: open threads (`stats.json`
   `open_threads`/`people/<slug>.md` `## Open threads`) and a one-line summary
   of the last interaction.

`why` is never bare cadence ("it's been a while") — it always cites the
specific signal and its evidence, even for a `tier-drift`/staleness-origin
nudge, which still names the actual gap (`median_gap_days`, `last_interaction`)
rather than a generic prompt.

## Worked examples

Weights below are illustrative calibrated values from `ranking-weights.md`'s
own example entries, used here only to demonstrate the arithmetic.

### Example A — `busy` week, close tie, scheduling-intent

- Person: `tier: close`, `last_interaction` 10 days ago, `touchpoints: 12`, no tags.
- `W = 0.85 (close) × 1.0 (d≤30) × 1.0 (≥10) = 0.85`
- `weekly_tier: busy` → `W′ = W = 0.85`
- `type: scheduling-intent` → `R = 1.0`; `confidence: high` → `C = 1.0`
- `weight(signal-type)`, `weight(tag)`: no entries → both `1.0`
- `Score = 0.85 × 1.0 × 1.0 × 1.0 × 1.0 = 0.850`

### Example B — `normal` week, active tie, job-change, tagged

- Person: `tier: active`, `last_interaction` 100 days ago, `touchpoints: 5`, tags include `college-friend`.
- `W = 0.65 (active) × 0.6 (d≤180) × 0.85 (4–9) = 0.3315`
- `weekly_tier: normal` → `W′ = 0.5 + 0.5 × 0.3315 = 0.66575`
- `type: job-change` → `R = 0.7`; `confidence: medium` → `C = 0.7`
- `weight(signal-type)` for `job-change`: `0.9` (calibrated down — crowd-visible); `weight(tag)` for `college-friend`: `1.15` (`ranking-weights.md`'s own example)
- `Score = 0.66575 × 0.7 × 0.7 × 0.9 × 1.15 = 0.337635 → 0.338`

### Example C — `open` week, dormant tie, tier-drift, W′ capped

- Person: `tier: dormant`, `last_interaction` 200 days ago, `touchpoints: 0`, no tags.
- `W = 0.4 (dormant) × 0.4 (d>180) × 0.5 (0 touchpoints) = 0.08`
- `weekly_tier: open`, `d = 200 > 180` → `S = 0.5`
- `W′ = (1 − 0.08) + 0.5 = 1.42 → capped at 1.0`
- `type: tier-drift` → `R = 0.6`; `confidence: high` → `C = 1.0`
- `weight(signal-type)`, `weight(tag)`: no entries → both `1.0`
- `Score = 1.0 × 0.6 × 1.0 × 1.0 × 1.0 = 0.600`

### Example D — two-signal boost

Suppose, alongside Example A's `scheduling-intent` signal (score `0.850`
before boost), the same person also has a `co-attendance` signal event
detected 3 days earlier — a different type within the trailing 14 days.
Both signal events' scores are multiplied by `1.5`:

- `scheduling-intent`: `0.850 × 1.5 = 1.275` (score is not re-capped —
  only `W′` in §2 is capped, not the final score)
- `co-attendance` (say its own base score was `0.500`): `0.500 × 1.5 = 0.750`

The promoted wake-up (whichever of the two, or both, clears the budget line)
opens its `## Context` with:
`Priority: high (two independent signals: scheduling-intent, co-attendance)`.

## Invariants a checker verifies

- Every `W′` value lies in `[0, 1]` inclusive — `open`-week values are capped
  at `1.0` even when `(1 − W) + S` arithmetic exceeds it.
- Every promoted or held signal's score is reproducible by hand from
  `stats.json`, `people/<slug>.md` tags, `ranking-weights.json`, and the
  signal event's `type`/`confidence`, using only §1–§6's tables and formula.
- No signal event is ever deleted for scoring `< 0.15` or for being held —
  suppression and holding are both logged states, never removals
  (`wakeups/signals/` stays append-only).
- A `low`-confidence signal event never appears alone as a promoted wake-up;
  it only promotes as part of a two-signal pairing.
- `origin: user-ask` wake-ups never appear in the budget count or the
  hold/suppress/promote table's accounting.
- No promoted wake-up's `## Context` has a bare-cadence `why` — every `why`
  cites the specific signal and evidence per §11, even for staleness/
  tier-drift-origin nudges.
- The number of promotions in any single sweep never exceeds
  `promotable_count` from §8, and every candidate below that line is present
  in the next sweep's ranking pass (not silently dropped).
- A missing or stale (`> 8` days) `week-plan.json` is logged and treated as
  `normal`/`budget.max = 3`, never as an unbounded or zero budget.
