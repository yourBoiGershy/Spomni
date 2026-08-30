# Spec: rescale

Status: spec (plan 30 unit 5). Package: ingestion. Script of record:
`packages/ingestion/scripts/rescale-scores.sh` (unit 9). Pure function over
a judgment batch; never writes the store. This spec covers `attention_warrant`
rescaling only — it does not cover `ranking-weights.json`'s ranking-weights
dimension rescale, which belongs to attention's own calibration spec (see
"Out of scope").

## Input

A JSONL file, one judgment record per line, per
`contracts/relationship-scoring.md`'s "Judgment record" shape. This spec
reads at least `slug`, `attention_warrant`, `kind`, `suggested_tier` from
each record; other fields (`kind_note`, `kind_expires`, `rationale`,
`confidence`) pass through unmodified.

## `--report`

Prints a fixed-format report, tab-separated, one header row followed by one
row **overall** and one row **per distinct `kind`** present in the batch
(kind rows in the order the kind first appears in the input file):

```
scope	n	mean	median	spread	share_ge_80	share_le_20	skew
```

- `scope` — literal `overall`, or the kind name for a per-kind row.
- `n` — record count in scope.
- `mean` — arithmetic mean of `attention_warrant` in scope, **1 decimal**.
- `median` — standard median (average of the two middle values for even
  `n`), unrounded beyond the input's own precision (integers in, so the
  even-`n` case may produce a `.5`; render as-is, no forced decimal count).
- `spread` — `p90 − p10` (see "Percentile method" below), same rendering
  rule as `median`.
- `share_ge_80` — fraction of scope with `attention_warrant >= 80`,
  **2 decimals**.
- `share_le_20` — fraction of scope with `attention_warrant <= 20`,
  **2 decimals**.
- `skew` — `yes` or `no` (or `n/a (n<4)` — see below), computed **per row**
  from that row's own `n`/`share_ge_80`/`share_le_20`/`spread`.

**Percentile method (p10/p90).** Linear interpolation on the sorted
scope, 0-based: for percentile `p`, `index = (p / 100) * (n − 1)`; when
`index` is not an integer, interpolate between `sorted[floor(index)]` and
`sorted[ceil(index)]` by the fractional part. `n = 1` makes `p10 = p90 =`
the single value (`spread = 0`).

**Skew rule.** `n >= 4` required to judge skew at all — below that,
`skew: n/a (n<4)` (a single-kind slice with 3 or fewer records is too small
to call skewed either way). For `n >= 4`:

```
skew: yes   when share_ge_80 > 0.5, or share_le_20 > 0.5, or spread < 10
skew: no    otherwise
```

`skew: yes` never carries a reason code in the report row itself — the
triggering condition is derivable by re-reading the row's own columns.

## Re-center (`--rescale --target-mean 50 --target-spread 40`, defaults shown)

Applies to every record, using the **overall** batch's `mean` and `spread`
(not per-kind — one shift-and-scale for the whole batch, so relative
comparisons across kinds survive the rescale):

```
w' = clamp(round(target_mean + (w − mean) * (target_spread / spread)), 0, 100)
```

When the overall `spread == 0` (every warrant identical, or `n <= 1`), the
scale factor is undefined — use shift-only: `w' = target_mean` for every
record (all records collapse to the target mean, since there is no spread
to preserve a ranking from).

`round()` is round-half-up (`x + 0.5 | floor` for `x >= 0`, which is the
only case here since warrants are non-negative).

**Ordering preserved.** For any two records `a`, `b` in the input batch,
`a.attention_warrant < b.attention_warrant` implies `a.w' <= b.w'` (the
shift-and-scale is monotonic; strict inequality can collapse to equality
only through the `clamp` at the 0/100 boundaries or through integer
rounding of two very close inputs — never inverts).

**Idempotent, within tolerance.** Running `--rescale` on a batch whose
overall `mean` is already within `target_mean ± 0.5` and whose overall
`spread` is already within `target_spread ± 1` is a no-op: every `w'`
equals its input `w` (the tolerance exists because integer-rounded warrants
re-measured after a prior rescale rarely land on the target exactly).
Outside that tolerance, a second `--rescale` pass over already-rescaled
output moves the batch closer to (but not necessarily exactly onto) the
target on that second pass, same formula, no special-cased detection of
"already rescaled."

**Suggested-tier recompute (re-centering only).** `suggested_tier` is
recomputed from each record's `w'` through a fixed band table, then
through `contracts/relationship-scoring.md`'s `## Rules` kind caps. This
band table exists **only** so a rescaled batch has tiers to show — it is
not the judgment's own rule and must never be cited as one:

| `w'` | Band |
|---|---|
| `>= 80` | `inner-circle` |
| `>= 60` and `< 80` | `close` |
| `>= 35` and `< 60` | `active` |
| `< 35` | `dormant` |

Then the kind caps from `contracts/relationship-scoring.md` `## Rules`
apply exactly as they do to any suggestion: `kind` in
`scheduling | transactional | unsolicited` never suggests above `active`;
`kind: unknown` never suggests above `close`. A rescale never bypasses a
rule — a capped record's recomputed tier is the capped value, not the raw
band lookup.

**Output shape.** Same JSONL, one line per input record, in input order,
with `attention_warrant` replaced by `w'`, `suggested_tier` replaced by the
recomputed tier, and a new field `rescaled_from: <original warrant>`
(the pre-rescale integer) added. All other fields pass through unchanged.

## `--rank`

Alternative to re-centering: percentile-band assignment instead of
shift-and-scale, computed over the **overall** batch (same
whole-batch-not-per-kind scope as re-center):

```
w' = round(100 * (rank − 0.5) / n)
```

`rank` is the record's 1-based rank in the batch sorted by
`attention_warrant` ascending; **ties share the mean rank** (e.g. three
records tied at the same warrant occupying ranks 4–6 all use `rank = 5`).
Same `round()` (half-up). Same suggested-tier recompute (band table, then
kind caps) applies to the `--rank` output as to `--rescale`'s. Output
shape is identical to re-center's (`attention_warrant`, `suggested_tier`,
`rescaled_from`, same JSONL structure).

## Worked example

Six-record batch, all `attention_warrant > 80`:

| slug | kind | `attention_warrant` |
|---|---|---|
| a | friend | 82 |
| b | collaborator | 85 |
| c | professional | 88 |
| d | family | 90 |
| e | transactional | 95 |
| f | scheduling | 99 |

**`--report` (overall row):**

```
scope	n	mean	median	spread	share_ge_80	share_le_20	skew
overall	6	89.8	89	13.5	1.00	0.00	yes
```

- `mean` = (82+85+88+90+95+99)/6 = 539/6 = 89.8333… → `89.8`.
- `median` = average of the 3rd/4th sorted values (88, 90) = `89`.
- `p10` = interpolate at index `0.5` between sorted[0]=82, sorted[1]=85 =
  `83.5`; `p90` = interpolate at index `4.5` between sorted[4]=95,
  sorted[5]=99 = `97`; `spread` = `97 − 83.5` = `13.5`.
- `share_ge_80` = 6/6 = `1.00`; `share_le_20` = 0/6 = `0.00`.
- `skew: yes` — `share_ge_80 (1.00) > 0.5` (also would qualify on
  `share_le_20`'s complement not applying, but the `share_ge_80` condition
  alone is sufficient).

Per-kind rows all have `n = 1 < 4`, so every kind row reads
`skew: n/a (n<4)`, e.g.:

```
scope	n	mean	median	spread	share_ge_80	share_le_20	skew
friend	1	82.0	82	0	1.00	0.00	n/a (n<4)
```

(and similarly for the other five kinds, each `mean` = its one value with
one decimal, `median` = that value, `spread = 0`).

**`--rescale --target-mean 50 --target-spread 40` (default target):**

`factor = target_spread / spread = 40 / 13.5 = 2.962963…`, applied to each
record via `w' = clamp(round(50 + (w − 89.8333…) * factor), 0, 100)`:

| slug | `w` | `w − mean` | `× factor` | `+ 50` | `w'` (rounded) |
|---|---|---|---|---|---|
| a | 82 | −7.8333 | −23.2099 | 26.7901 | 27 |
| b | 85 | −4.8333 | −14.3210 | 35.6790 | 36 |
| c | 88 | −1.8333 | −5.4321 | 44.5679 | 45 |
| d | 90 | 0.1667 | 0.4938 | 50.4938 | 50 |
| e | 95 | 5.1667 | 15.3086 | 65.3086 | 65 |
| f | 99 | 9.1667 | 27.1605 | 77.1605 | 77 |

Ordering preserved: 27 < 36 < 45 < 50 < 65 < 77, same order as the inputs.
Re-measuring the rescaled batch: `mean = 300/6 = 50.0` (target `50`, within
tolerance), `spread`: sorted rescaled = 27,36,45,50,65,77; `p10` interpolates
27→36 at index 0.5 = `31.5`, `p90` interpolates 65→77 at index 4.5 = `71`,
`spread = 39.5` (target `40`, within the `± 1` idempotency tolerance) — a
third rescale pass over this output would be a no-op.

**Suggested-tier recompute** (band table, then kind caps):

| slug | `w'` | band | kind | cap applies? | `suggested_tier` |
|---|---|---|---|---|---|
| a | 27 | dormant | friend | no | dormant |
| b | 36 | active | collaborator | no | active |
| c | 45 | active | professional | no | active |
| d | 50 | active | family | no | active |
| e | 65 | close | transactional | yes → cap at active | active |
| f | 77 | close | scheduling | yes → cap at active | active |

Records `e` and `f` land in the `close` band by raw `w'` but are capped
down to `active` by their kind caps — this is the "a rescale never bypasses
a rule" clause in action.

**Output** (`e`'s line, as an example of the full replacement shape):

```json
{"slug": "e", "attention_warrant": 65, "kind": "transactional", "suggested_tier": "active", "rescaled_from": 95, "...": "other fields pass through"}
```

## Never silent

The presenting skill always shows `--report`'s output first; `--rescale`
or `--rank` is only applied on top of an already-visible report, never
silently substituted for the raw judgment batch. When a rescale is applied,
every breakdown string the skill presents
(`contracts/relationship-scoring.md` "## Breakdown string") appends:

```
| rescaled: <from>→<to>
```

using that record's `rescaled_from` value and its new `attention_warrant`,
e.g. `| rescaled: 95→65`. A batch shown without `--rescale`/`--rank` never
carries this segment.

## Deterministic checkability

Given a fixture JSONL batch, a checker can hand-verify, without any
judgment call:

1. The exact overall and per-kind `--report` rows (mean/median/spread/
   shares/skew), including the `n < 4` `skew: n/a` case per kind.
2. The exact `p10`/`p90` interpolated values for any given sorted scope.
3. Every record's rescaled `w'` under `--rescale` (or `--rank`), by hand,
   from the formula and the fixture's `mean`/`spread` (or ranks).
4. That ordering is preserved end to end (no output `w'` pair inverts a
   relative order present in the input).
5. That a fixture already at target mean/spread within tolerance produces
   an unchanged batch under `--rescale` (the idempotency case).
6. Every record's recomputed `suggested_tier`, including which records a
   kind cap pulls down from the raw band lookup.
7. That the presented breakdown string carries the `| rescaled: <from>→<to>`
   segment only when `--rescale`/`--rank` was applied, and never otherwise.

## Out of scope

- `packages/attention/specs/calibration.md`'s ranking-weights dimension
  rescale (plan 30 unit 16) — a different rescale target
  (`ranking-weights.json`'s `kinds`/`evidence` multiplier dimensions,
  `contracts/ranking-weights.md`), over a different input shape, owned by
  attention, not this spec. Do not conflate the two: this spec rescales a
  batch of per-person `attention_warrant` judgment outputs; that spec
  rescales the stored weight priors that feed the *next* judgment.
- The review-tiers skill's UI/prompt flow around presenting `--report` and
  offering `--rescale`/`--rank` — this spec defines only the script's pure
  computation and required output shapes, not the skill's conversational
  wrapper.
- Persisting any rescaled value to `person.md` or any store file — this
  script writes no store file itself, ever (see Status line); persistence,
  if any, happens through the ordinary confirmed-tier write path
  (`stated-preference-filing.md`), unowned by this spec.
