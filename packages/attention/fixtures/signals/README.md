# Signal-engine golden fixture (plan 05)

A single seeded store (`store/`) exercising all five v1 signal detectors —
birthday, job-change, co-attendance, company-news, linkedin-post — plus the
`packages/attention/specs/ranking.md` scoring/budget/hold/suppress pipeline,
so a checker can run `signal-scan` (or hand-walk the arithmetic below)
against `store/` and diff the result against `expected/`.

## Scan anchor

- Sweep run date ("today"): **2026-09-01** (a Tuesday).
- `store/signals/week-plan.json`: `week_start: 2026-08-31`, `weekly_tier:
  normal`, `budget: {"min": 2, "max": 3}` — shape copied from
  `packages/attention/fixtures/capacity/mixed-week/expected/week-plan.json`.
- No existing `wakeups/*.md` with `origin: signal` due inside the plan
  week — `store/wakeups/` and `store/wakeups/signals/` are both empty
  (`.gitkeep` only) — so `promotable_count = budget.max − 0 = 3`
  (`ranking.md` §8).
- No `store/ranking-weights.json` — every `weight(signal-type)` and
  `weight(tag)` term in `ranking.md` §5 defaults to `1.0`.
- `store/profile.md` has an empty `## Signal opt-outs` section — no
  detector is gated by an opt-out in this fixture.

## Personas

Copied verbatim from `packages/core/fixtures/store/people/`, with three
scenario-required field edits (every other line — tags, facts, open
threads, personal details — is untouched):

| Persona | Tier | Edit made | Why |
|---|---|---|---|
| `walter-combs` | inner-circle | none | co-attendance (primary of the pair) |
| `ayesha-malik` | active | none | co-attendance (secondary of the pair) |
| `marcus-chen` | active | `org: Vantage Financial` → `org: Northwind Labs` | required by scenario 4 below — represents the store already reflecting the job-change signal's destination employer, so the company-news detector's "search per contact's org" step targets the right company. See the narrative note under scenario 4. |
| `ben-whitmore` | close | `birthday: --06-22` → `birthday: --09-06` | puts his birthday exactly 5 days out from the scan date |
| `aiko-tanaka` | dormant | `tags: [college-friend, science]` → `[college-friend, science, bell]` | marks her as the "belled" contact the linkedin-post detector watches |

## Scenarios

1. **birthday — `ben-whitmore`.** `people/ben-whitmore.md` has `birthday:
   --09-06`, 5 days after the scan date. Per `specs/birthday.md`,
   frontmatter-stated → `confidence: high`, evidence `Birthday 09-06
   [stated-by-user] (people/ben-whitmore.md)`, due = day before = **2026-09-05**.
2. **job-change — `marcus-chen`.** `inbox/20260830T090000Z-gmail-in-jc01.md`
   (`type: linkedin-notification`, source `gmail-in`) quotes "Marcus Chen
   started a new position as VP Product at Northwind Labs." Per
   `specs/job-change.md`, a LinkedIn-notification match with no signature
   diff and no web-search corroboration on file → `confidence: medium`, due
   = detected + 14 days = **2026-09-15**.
3. **co-attendance — `walter-combs` + `ayesha-malik`.**
   `interactions/2026-08-31-walter-combs-ayesha-malik.md` carries
   `calendar-event: evt-fixture-panel` and the same-event-as marker "Met at
   the same event as [[ayesha-malik]]" in its `## Summary`. Per
   `specs/co-attendance.md`'s filed-interaction path (rule 1) →
   `confidence: high`, `person: ["[[walter-combs]]", "[[ayesha-malik]]"]`,
   due = day after the event = **2026-09-01**.
4. **company-news — `marcus-chen`.**
   `inbox/20260829T120000Z-web-search-cn01.md` (`type: other`, `source:
   web-search`) is a saved search result: "Northwind Labs raises $40M
   Series B." Marcus Chen's `org` is Northwind Labs (see the persona-edit
   table above) → `confidence: medium`, due = detected + 2 days =
   **2026-09-03**. *Narrative note:* this fixture is a single-sweep
   snapshot for ranking arithmetic, not a live multi-sweep pipeline replay
   — `org` is pre-set to Northwind Labs so the company-news detector's
   per-contact search targets the same company the job-change signal
   names, giving marcus-chen two independent, corroborating signal
   *types* within 14 days (see the two-signal rule below). This does not
   contradict `specs/job-change.md`'s "detector never writes org/role
   directly" rule — that rule constrains the *live* detector's behavior,
   not this fixture's seeded starting state.
5. **linkedin-post — `aiko-tanaka` (dormant, belled).**
   `inbox/20260831T100000Z-gmail-in-lp01.md` (`type: linkedin-notification`,
   source `gmail-in`): "Aiko Tanaka posted: new results from our battery
   materials work are up." `confidence: low` (a single "ring the bell"
   notification, no corroboration). `interactions/2026-01-15-aiko-tanaka.md`
   is her only filed interaction, 229 days before the scan date, keeping
   her `dormant` recency bucket (`> 180` days) live.

**Two-signal rule:** `marcus-chen` carries two signal events of different
`type` (`job-change`, `company-news`) both `detected_at: 2026-09-01`,
inside the trailing 14 days — per `ranking.md` §6, both scores are
multiplied by `×1.5`, and both promoted wake-ups open `## Context` with
`Priority: high (two independent signals: job-change, company-news)`.

## `stats.json` (via `build-stats.sh`, committed alongside `store/`)

Running `bash packages/core/scripts/build-stats.sh
packages/attention/fixtures/signals/store` produces (irrelevant
`commitments`/`median_gap_days`/`open_threads` fields omitted for brevity —
full file is `store/stats.json`):

| Person | tier | touchpoints | last_interaction | days to 2026-09-01 |
|---|---|---|---|---|
| `walter-combs` | inner-circle | 1 | 2026-08-31 | 1 |
| `ayesha-malik` | active | 1 | 2026-08-31 | 1 |
| `marcus-chen` | active | 2 | 2026-08-15 | 17 |
| `ben-whitmore` | close | 1 | 2026-08-15 | 17 |
| `aiko-tanaka` | dormant | 1 | 2026-01-15 | 229 |

These are the exact numbers the ranking table below plugs into `ranking.md`
§1's tier/recency/density tables — the README's arithmetic is not
independently guessed, it is read straight off `stats.json`.

## Ranking (full arithmetic — see `expected/ranking.md` for the final table)

Formula, per `packages/attention/specs/ranking.md` §1–§6 (`weekly_tier:
normal` → `W′ = 0.5 + 0.5·W`; no `ranking-weights.json` → both weight terms
= `1.0`):

```
W = tier × recency × density
W′ = 0.5 + 0.5·W                      (normal week)
Score = W′ × R × C                    (× 1.5 twice for marcus-chen's pair)
```

**Co-attendance multi-person convention** (not spelled out by
`ranking.md`/`co-attendance.md`, fixed here for this fixture): the pair's
`W` is taken from the **higher-tier** of the two people —
`walter-combs` (inner-circle) over `ayesha-malik` (active) — since
`ranking.md`'s inputs table keys warmth off a single `stats.json`
`people.<slug>` entry and the spec is silent on pair-resolution; using the
warmer half is the more actionable, defensible choice.

| Signal | Person | tier | recency (d) | density (touchpoints) | W | W′ | R | C | ×1.5? | Score |
|---|---|---|---|---|---|---|---|---|---|---|
| co-attendance | walter-combs (primary) | 1.0 | 1.0 (d=1) | 0.7 (1) | 0.700 | 0.850 | 0.9 | 1.0 (high) | no | **0.765** |
| company-news | marcus-chen | 0.65 | 1.0 (d=17) | 0.7 (2) | 0.455 | 0.7275 | 0.8 | 0.7 (medium) | yes | **0.611** |
| job-change | marcus-chen | 0.65 | 1.0 (d=17) | 0.7 (2) | 0.455 | 0.7275 | 0.7 | 0.7 (medium) | yes | **0.535** |
| birthday | ben-whitmore | 0.85 | 1.0 (d=17) | 0.7 (1) | 0.595 | 0.7975 | 0.5 | 1.0 (high) | no | **0.399** |
| linkedin-post | aiko-tanaka | 0.4 | 0.4 (d=229) | 0.7 (1) | 0.112 | 0.556 | 0.3 | 0.4 (low) | no | **0.067** |

Arithmetic detail on the two boosted rows:

- `company-news`: `0.7275 × 0.8 × 0.7 = 0.4074`; `× 1.5 = 0.6111 → 0.611`.
- `job-change`: `0.7275 × 0.7 × 0.7 = 0.356475`; `× 1.5 = 0.5347125 → 0.535`.

## Budget / hold / suppress (`ranking.md` §7–§8)

`promotable_count = 3` (budget.max, no pre-existing signal wake-ups).
Ranking descending by score:

1. co-attendance (walter-combs+ayesha-malik) — **0.765** → promoted
2. company-news (marcus-chen) — **0.611** → promoted
3. job-change (marcus-chen) — **0.535** → promoted
4. birthday (ben-whitmore) — **0.399** → **HELD** (below the top-3 budget line, score ≥ 0.15 so not suppressed — re-ranked next sweep)
5. linkedin-post (aiko-tanaka) — **0.067** → **SUPPRESSED** (< 0.15 floor; also a lone low-confidence signal with no different-type companion for aiko-tanaka within 14 days, so it could never have self-promoted regardless of score)

All five signal events are written to `expected/signal-events/`
(append-only per `signal-event.md` — suppression/holding never deletes the
log entry). Only the top-3 promoted signals get a `wakeups/<id>.md` file in
`expected/wakeups/`.

## How a checker should compare

1. Run the sweep's `signal-scan` skill (or the ranking pass standalone)
   against `store/`, with `--today 2026-09-01`.
2. Diff every emitted file in `store/wakeups/signals/*.md` against
   `expected/signal-events/*.md` — five files, `id`/`type`/`person`/
   `confidence` must match exactly; `evidence` text should be
   semantically equivalent (exact wording is illustrative, not
   byte-contractual, per `signal-event.md`).
3. Diff every emitted file in `store/wakeups/*.md` (excluding the
   `signals/` subdir) against `expected/wakeups/*.md` — exactly three
   files, matching `id`/`due`/`people`/`why`/`origin`/`source-signal`/
   `signal-type`; `## Context` must open with the `Priority: high (two
   independent signals: ...)` line for both `marcus-chen` wake-ups.
4. Confirm the birthday signal for `ben-whitmore` is logged but **not**
   promoted this pass, and the linkedin-post signal for `aiko-tanaka` is
   logged with `suppressed: floor` in the scan log and not promoted.
5. Confirm no more than 3 wake-ups were created (the budget line), and
   that the held birthday signal is not silently dropped — it must still
   be present in `store/wakeups/signals/`.

## Validation

```
$ bash packages/core/scripts/validate-store.sh packages/attention/fixtures/signals/store
store clean: 11 files checked

$ bash packages/core/scripts/build-stats.sh packages/attention/fixtures/signals/store
stats for 5 people → packages/attention/fixtures/signals/store/stats.json
```

`store/stats.json` is committed alongside `store/` so the scan and a
checker read the same numbers this README's table cites.
