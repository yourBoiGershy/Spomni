# Spec: calibration (wake-up outcome history → ranking-weights.json)

Status: Sketch/spec for plan 06's sweep `calibrate` step (plan 11 unit 9).
Field names, clamps, and the interpretability contract are verbatim from
`packages/core/contracts/ranking-weights.md` (1.0.0) and
`packages/core/contracts/wakeup.md` (1.1.0); this spec does not re-litigate
either — it specs how attention's sweep aggregates the latter into the
former. Sibling spec `packages/attention/specs/outcome-recording.md` (unit 8)
produces the `fired-on` / `dismiss-reason` / `acted-on` / `snooze-count`
fields this spec reads; it does not write them.

**Caller:** plan 06's `skills/sweep/SKILL.md` pipeline. Per
`outcome-recording.md` section 3, the ordering is:

```
... → fire due wake-ups → acted-on detection → calibrate (this spec) → deliver via output adapter
```

`calibrate` runs once per sweep invocation, after acted-on detection has had
a chance to settle outcomes for the run's window.

## Scope

Reads `wakeups/*.md` (outcome fields only — never writes them; attention's
lifecycle ops own those, per `wakeup.md`'s writer table) plus `people/*.md`
(`tags` frontmatter only, read-only join) and the store's *previous*
`ranking-weights.json` (if present, as the per-step clamp baseline). Produces
a full rewrite of `ranking-weights.json` — the sole write this step performs
on that file — plus, as a side effect, may create at most one new
`wakeups/<id>.md` suppression-proposal entry per person per run via
`wakeup-add.sh` (see section 4). It never touches `profile.md` (ingestion's
sole-writer territory, per `docs/DECISIONS.md#attention-merge` and plan 11's
single-writer table) — a confirmed suppression proposal is filed by
ingestion, not by this step.

## 1. Aggregation window

Default **90 days**, ending at the sweep's run date ("today"). Configurable
via `calibrate.sh`'s `--window-days <n>` flag for testing/fixtures.

A `wakeups/<id>.md` entry is **in-window** iff its outcome-anchoring date
falls within `(today - window-days, today]`:

- If `fired-on` is non-null, use `fired-on` (an entry's outcome — dismissal,
  snooze, acted-on — is anchored to when it was presented to the user, not
  when it was created or when it happens to be due).
- Else, use `due` (an entry that was dismissed or snoozed before ever firing
  still carries a `due` date and should not be silently excluded from
  calibration just because `outcome-recording.md`'s `fire` path never ran on
  it).

Entries entirely outside the window are ignored by this run — consistent
with the contract's regenerable-from-history semantics: the *file* is a full
rewrite each run, but re-running today after new history has aged out of the
window can legitimately produce a different (more neutral) weight than
yesterday's run for the same key, exactly as `stats.json` would.

## 2. Per-key stat collection

Two independent aggregations run over the same in-window entry set: one
keyed by **signal-type**, one keyed by **tag**. A single wake-up entry may
contribute to zero, one, or several keys in each dimension (see 2.2 below);
counts are not mutually exclusive across keys.

For every in-window entry, the raw facts pulled are: `status`,
`dismiss-reason`, `acted-on`, `snooze-count`, `origin`, `source-signal`,
`people` (list of slugs).

### 2.1 Signal-type derivation

`wakeup.md` (1.1.0) carries an optional `signal-type` frontmatter field
(kebab-case, e.g. `birthday`, `job-change`) — additive over 1.0.0, per that
contract's field table. It is not yet universally populated: plan 05/06's
signal-scan and standing-nudge creation paths are the **required touchpoint**
that must SET it at creation time (when `origin: signal` or `origin:
standing`, per `wakeup.md`'s description of the field), so this remains a
live touchpoint to keep landing, not a closed gap.

Because the field can still be absent on entries created before that
touchpoint lands everywhere (or on any writer that omits it), `calibrate.sh`
degrades gracefully rather than guessing at hyphen-splitting the opaque
`source-signal` id (person slugs themselves contain hyphens, making any
split of `source-signal` ambiguous):

- If frontmatter `signal-type` is present, use it verbatim.
- Else, every such entry (`origin: signal` or `origin: standing` with no
  `signal-type` field) is bucketed under the literal key `unclassified`, so
  the aggregate counts are never silently dropped — they show up in
  `ranking-weights.json` under `"unclassified"` with a rationale that says
  as much (see the example in section 3), which is itself a visible nudge to
  confirm the plan 05/06 touchpoint is setting the field consistently.
- `origin: user-ask` entries are excluded from the signal-type dimension
  entirely — they are not signal-driven, so a signal-type dismissal reason
  doesn't apply to them semantically (a user explicitly asked to be
  reminded; that outcome speaks to nothing about signal-type ranking).

### 2.2 Tag derivation

For each in-window entry, resolve every `people` slug to `people/<slug>.md`'s
frontmatter `tags` list (per `packages/core/contracts/person.md`). The union
of tags across all listed people on that entry is the set of tag-keys this
entry contributes to (an entry with two people carrying three distinct tags
between them contributes once to each of the three tag buckets). A person
with no `tags` frontmatter, or a slug that no longer resolves to a
`people/<slug>.md` file, contributes to no tag bucket (silently skipped —
not an error; people/tags drift is common and not this step's job to flag).

### 2.3 Per-key counters

For each key (signal-type or tag), collect over its in-window contributing
entries:

| Counter | Definition |
|---|---|
| `fired` | count where `fired-on` is non-null (this key's denominator for both rates below) |
| `acted_on_true` | count where `acted-on == true` |
| `dismissed_total` | count where `status == dismissed` |
| `dismissed_not_this_signal_type` | count where `dismiss-reason == not-this-signal-type` |
| `dismissed_not_this_person` | count where `dismiss-reason == not-this-person` (excluded from this key's weight math — see 3.3 — but still tallied for the rationale string and for section 4's per-person suppression path) |
| `dismissed_other` | count where `dismiss-reason` is `not-now` or `already-handled` |
| `snoozed_total` | sum of `snooze-count` across contributing entries |

`fired == 0` for a key means no rate can be computed this run — see 3.1.

## 3. Weight adjustment formula

**One formula, applied identically to both dimensions**, differing only in
which dismissal counter feeds the negative term (per-dimension note below).
This mirrors the contract's two worked examples (`"4 of 5 birthday nudges
dismissed not-this-signal-type in 90d"` → weight moves down;
`"acted on 6 of 7 fired nudges"` → weight moves up) with one deterministic
rule, not two competing heuristics.

### 3.1 Minimum sample size

A key needs **`fired >= 3`** in-window to receive any adjustment this run.
Below that threshold, the key is left exactly as it appears in the *previous*
`ranking-weights.json` (untouched — no `updated`/`rationale` rewrite, since
there isn't enough evidence this run to justify moving or re-justifying it).
If the key has no prior entry either, it is simply absent from the output
(neutral `1.0` default, per the contract's absent-key semantics) — small
sample counts never manufacture a weight entry.

### 3.2 Rates

```
acted_on_rate   = acted_on_true / fired
neg_rate        = negative_counter / fired      (see 3.3 for negative_counter per dimension)
raw             = acted_on_rate - neg_rate
```

### 3.3 Negative counter per dimension

- **`signal-types`**: `negative_counter = dismissed_not_this_signal_type`
  — the brief's stated rule verbatim: only a signal-type-specific dismissal
  counts against a signal-type's weight. `not-now`/`already-handled`
  dismissals are recorded in the rationale text (for interpretability) but
  do not move the number — they say nothing about whether *this signal type*
  is unwelcome.
- **`tags`**: `negative_counter = dismissed_total - dismissed_not_this_person`
  — every dismissal reason except `not-this-person` counts against a tag's
  weight (a `not-this-signal-type` dismissal on a wake-up about a
  `college-friend`-tagged person is still evidence that *this kind of nudge*
  isn't landing for people carrying that tag). `not-this-person` dismissals
  are excluded from every weight-bearing dimension per the contract's
  "per-person suppression is out of scope" section — they flow only through
  section 4's proposal path, never into `neg_rate` anywhere.

### 3.4 Step and clamp

```
step        = clamp(raw, -0.15, +0.15)                     # per-step bound
prior       = previous ranking-weights.json's weight for this key, or 1.0
new_weight  = clamp(prior + step, 0.25, 2.0)                # absolute bound
```

Both clamps are the contract's verbatim numbers (`ranking-weights.md`
"Clamps" section) — this spec does not introduce new bounds.

If `new_weight == prior` (rounds to the same value — e.g. `raw == 0`, a
perfect wash of acted-on vs. dismissed), the key is left as-is: no
`updated`/`rationale` rewrite for a non-move, consistent with "every
*changed* entry gets `updated` + `rationale`" (brief) — an unchanged weight
is not a changed entry, even if it was recomputed.

Weights are rounded to 2 decimal places for the on-disk value (matching the
contract's example precision, e.g. `0.7`, `1.15`).

### 3.5 Rationale string

Every entry whose `weight` changed this run gets:

- `updated`: today's date (`YYYY-MM-DD`)
- `rationale`: built from the counts, mirroring the contract's example
  phrasing exactly:
  - Downward move, signal-types: `"<dismissed_not_this_signal_type> of <fired> <key> nudges dismissed not-this-signal-type in <window-days>d"`
    (matches `"4 of 5 birthday nudges dismissed not-this-signal-type in 90d"` verbatim)
  - Upward move, either dimension: `"acted on <acted_on_true> of <fired> fired nudges"`
    (matches `"acted on 6 of 7 fired nudges"` verbatim)
  - Downward move, tags: `"<negative_counter> of <fired> <key>-tagged nudges dismissed (excl. not-this-person) in <window-days>d"`
  - If both an upward and downward pressure are present but the net `step`
    is negative, use the downward phrasing (and vice versa) — the rationale
    always names the pattern that explains the *direction of the change*,
    never both at once, per the interpretability contract ("must describe
    ... the outcome evidence behind the change", one clear pattern per
    entry).
  - `unclassified` bucket entries additionally append: `" (signal-type not recorded on these wake-ups — see calibration.md §2.1)"` so the rationale itself surfaces the plan 05/06 gap to a human reading the file.

## 4. Per-person suppression proposal (`not-this-person`)

`not-this-person` dismissals never enter `ranking-weights.json` (section
3.3; contract's "Per-person suppression is out of scope"). Instead, this
step tracks them per person-slug, across *all* that person's in-window
wake-ups regardless of signal-type/tag:

- Count `dismissed_not_this_person` per slug within the window.
- **If count >= 2 for a slug**, and there is no existing `pending` or
  `fired` wake-up already proposing suppression for that slug (idempotency
  check: scan `wakeups/*.md` for an entry whose `people` includes the slug
  and whose `why` starts with the literal sentinel prefix
  `"stop nudging about "` — see below), create exactly one new proposal via
  `packages/core/scripts/wakeup-add.sh` (the only sanctioned creation path):

```
wakeup-add.sh <store-dir> \
  --due <today> \
  --person <slug> \
  --why "stop nudging about [[<slug>]]? <count> not-this-person dismissals in <window-days>d" \
  --origin signal \
  --source-signal "calibration-suppression-<slug>-<today>" \
  --context "<count> wake-ups about [[<slug>]] were dismissed not-this-person in the last <window-days> days: <comma-joined list of the dismissed entries' ids>. Confirming this proposal opts [[<slug>]] out via profile.md's Signal opt-outs (ingestion files it after user confirmation; attention never writes profile.md)."
```

`--source-signal` is required (non-null) by `wakeup-add.sh` whenever
`--origin signal` is given — it normally names the `wakeups/signals/<id>.md`
this entry was promoted from, per `wakeup.md`. A calibration-generated
suppression proposal has no such signal-event file behind it (plan 05's
`signal-event.md` is unbuilt); the synthetic id above is a placeholder
flagged the same way as the signal-type gap in section 2.1 — revisit once
plan 05/06 land (either a real signal-event file, or a `wakeup-add.sh`
allowance for an attention-internal origin that doesn't require one).

- This is a **proposal**, not a mutation: it surfaces as an ordinary
  wake-up the user reads like any other nudge. Confirming it is a chat/UI
  action outside this spec's scope; per plan 11's single-writer table,
  ingestion (not attention) files the resulting `profile.md` opt-out once
  confirmed. A declined proposal is dropped silently — never re-asked on
  the same evidence — which the idempotency check above already guarantees
  as long as the declined proposal's wake-up file is left at a terminal
  `status: dismissed` (a dismissed proposal no longer matches the "pending
  or fired" scan and could in principle be re-proposed if the *same* two
  dismissals recur combined with new ones; this spec accepts that
  edge case rather than inventing a second suppression-history ledger, since
  a declined proposal plus fresh independent evidence re-raising the
  question is not the "streak nagging" the no-guilt rule prohibits).
- **Open note (not this spec's to resolve):** `profile.md`'s current
  `## Signal opt-outs` grammar (`<signal-type> — [[slug]]` / `<signal-type>
  — all`) is scoped per signal-type, not a single blanket
  per-person-across-everything opt-out. "Stop nudging about X" as phrased
  above is broader than that grammar currently expresses. Until profile.md
  gains a person-level opt-out grammar (or until this proposal's `--why`
  is narrowed to name a specific signal-type), the confirmed-proposal →
  ingestion-filing step should file one opt-out bullet per signal-type this
  person triggered in-window, using the existing grammar — a workable
  interim mapping, not a contract change made here.

## 5. Output envelope

Full rewrite of `<store-dir>/ranking-weights.json` per
`packages/core/contracts/ranking-weights.md`'s shape exactly:

```json
{
  "schema_version": "1.0.0",
  "generated_at": "<ISO 8601 datetime, this run>",
  "weights": {
    "signal-types": { "<key>": { "weight": <num>, "updated": "<date>", "rationale": "<string>" } },
    "tags": { "<key>": { "weight": <num>, "updated": "<date>", "rationale": "<string>" } }
  }
}
```

- Keys with `fired < 3` this run (3.1) carry forward unchanged from the
  previous file if they existed there; keys with no evidence ever and no
  prior entry are omitted entirely (never pre-populated at `1.0`), per the
  contract's absent-key-default section.
- `weights.signal-types` / `weights.tags` may each be `{}` on a store with
  no calibration-worthy history yet (fresh store, or every key below the
  sample-size floor) — an empty map is valid per the contract.

## Regeneration semantics

Consistent with `ranking-weights.md`'s "Regenerable-from-history" section:
`wakeups/` (plus `people/*.md` tags, plus the previous `ranking-weights.json`
as the per-step clamp baseline) is the full input set; re-running `calibrate`
against the same input set produces the same output. Deleting
`ranking-weights.json` and re-running resets every key's clamp baseline to
`1.0` (section 3.4's "or 1.0" fallback) and recomputes fresh — reproducing an
equivalent-shape file per the contract, though not necessarily numerically
identical to a file that had accumulated several incremental steps, exactly
as the contract's Notes section anticipates ("no data is lost ... only the
record of prior calibration rationale text").

## Seeding from user-model (`--seed-from-user-model <store>`)

A one-shot (or revision-triggered) initialization of the `kinds` and
`evidence` dimensions of `ranking-weights.json` (1.1.0) from the store's
`data/store/user-model.md` — the "Priors, not multipliers" amendment's
seeding path, per `ranking-weights.md` 1.1.0 and `relationship-scoring.md`'s
`## Priors` section. This is a separate invocation from the sweep's normal
`calibrate` step (which only ever touches `signal-types`/`tags`) —
`--seed-from-user-model` is invoked explicitly (onboarding confirmation
flow, or a later revision confirmation), never silently folded into a sweep
run.

**Refusal:** the command accepts `user-model.md` frontmatter `status:
confirmed` or `status: provisional` (plan 31 D6 — a provisional model is
derived and auto-adopted, not user-stated, but is still a fit basis to seed
priors from). Any other status — `draft`, absent, or unrecognized — refuses
and exits **3**, with no partial write and no `ranking-weights.json` touch
at all. This differs from the drift judgment's stricter `confirmed`-only
gate (`tier-drift.md` "## Judgment verdict"), which still ignores
provisional models.

### `kinds.*` derivation

Each kind in the vocabulary (`friend, family, collaborator, professional,
community, scheduling, transactional, unsolicited, unknown`) maps to one of
`user-model.md`'s five `## Investment mix` axes (`business`, `friends`,
`family`, `community`, `transactional`) via a fixed axis map:

| kind | axis |
|---|---|
| `friend` | `friends` |
| `family` | `family` |
| `collaborator` | `business` |
| `professional` | `business` |
| `community` | `community` |
| `transactional` | `transactional` |
| `scheduling` | `transactional` |
| `unsolicited` | `transactional` |
| `unknown` | *(no axis — see below)* |

For every mapped kind, read the axis's confirmed weight (`## Investment
mix`, `<axis>: <weight 0-1>`) and compute:

```
axis_weight = <the axis's 0-1 weight>
weight      = 0.5 + axis_weight              # 0.0 -> 0.5, 0.5 -> 1.0 (neutral), 1.0 -> 1.5
weight      = clamp(weight, 0.25, 2.0)
```

`kind: unknown` has no axis mapping and is left at the neutral default
(absent from the seeded output — same absent-key-default semantics as any
other key with no evidence, per `ranking-weights.md`).

**Protected-time lift:** if the `## Protected time` prose names the axis a
kind maps to (a plain substring/keyword match against the axis name or its
common synonyms, e.g. "friends" text matching the `friends` axis, "family"
matching `family`), that kind's seeded `weight` is lifted to `max(weight,
1.0)` — protected time is a floor signal ("this axis is protected — never
seed it below neutral"), not an override of a genuinely high axis weight
above `1.0`.

### `evidence.*` derivation

`evidence.*` is seeded to a fixed default set on every seeding run
(independent of the user-model's per-axis weights — the evidence dimension
reflects general evidence-strength priors, not per-axis investment):

| evidence key | seeded weight |
|---|---|
| `meeting` | 1.5 |
| `co_attended` | 1.3 |
| `user_initiated` | 1.2 |
| `talking_point` | 1.2 |
| `email` | 1.0 |
| `chat_day` | 0.8 |

### Rationale, first-write exemption, revision-aware re-seed

- Every seeded entry (`kinds.*` and `evidence.*`) gets `rationale: "seeded
  from user-model revision <n>"` (`<n>` = `user-model.md`'s confirmed
  `revision` field) and `updated: <today>`.
- **First-write exemption:** a seeding run's writes to a previously-absent
  key are exempt from the per-step `±0.15` bound (`ranking-weights.md`
  1.1.0 clause (i), "First-write seeding") — the seeded value may land
  anywhere in `[0.25, 2.0]` per the formulas above.
- **Revision-aware re-seed:** on a later seeding run (the user re-confirms
  `user-model.md` and its `revision` bumps), only keys whose *current*
  `rationale` names an **older** revision number than the new one are
  re-seeded (overwritten per the formulas above, with the new revision
  number in the rationale). Any key whose rationale does **not** match the
  `"seeded from user-model revision <n>"` pattern — i.e. it was since
  touched by the normal `calibrate` step or hand-edited — is a **user-tuned
  entry** and is left untouched by re-seeding, regardless of how stale the
  user-model revision it was originally seeded from is. This mirrors the
  contract's stated-outranks-revealed posture: once a value has organic
  outcome evidence behind it, a later seed pass does not clobber it.

### Worked example

`user-model.md` (confirmed, `revision: 2`) has `## Investment mix` axis
`friends: 0.8 — regular weekly hangs` and `## Protected time` prose "regular
friends — weekly-ish hangs are non-negotiable; family dinners always win."

- `kinds.friend` seeds to `clamp(0.5 + 0.8, 0.25, 2.0) = 1.3`, then the
  protected-time lift checks: `## Protected time` names "friends" →
  `max(1.3, 1.0) = 1.3` (already above floor, no change) — `rationale:
  "seeded from user-model revision 2"`.
- If instead `friends: 0.2` (weight `0.7`, below the `1.0` floor) and
  "friends" is still named in `## Protected time`, the lift applies:
  `max(0.7, 1.0) = 1.0`.
- `evidence.meeting` seeds to `1.5` regardless of axis weights —
  `rationale: "seeded from user-model revision 2"`.
- A later run against `revision: 3` re-seeds `kinds.friend` (its rationale
  names revision 2, older than 3) but skips `kinds.professional` if that
  key's current rationale reads `"acted on 6 of 7 fired nudges"` (a
  `calibrate`-step rewrite, not a seed rationale) — that entry is user-tuned
  and survives.

## Rescale (`--rescale <dimension>`)

A **user-invoked** post-processing step over one weight dimension
(`kinds`, `evidence`, `signal-types`, or `tags`) — renormalizes that
dimension so its geometric mean lands at `1.0` while preserving the
*ratios* between entries, per `ranking-weights.md` 1.1.0 clause (ii) ("the
rescale exemption"). This is never invoked as part of the sweep pipeline —
it is a standalone `calibrate.sh --rescale <dimension>` call the user (or an
operator) runs explicitly, e.g. after noticing a dimension has drifted
lopsided over many small calibration steps.

### Formula

```
geomean = ( product of all weight[k] for k in dimension ) ^ (1 / count)
w'[k]   = weight[k] / geomean                      # preserves ratios
w'[k]   = clamp(w'[k], 0.25, 2.0)                   # then clamp
```

Clamping after the divide can pull the post-clamp mean slightly off `1.0`
when one or more entries would otherwise land outside `[0.25, 2.0]`
post-rescale — this is an accepted, documented approximation, not a bug:
the absolute bound (`ranking-weights.md` "Clamps") always wins over exact
mean-centering.

- **Exempt from the per-step `±0.15` bound** (clause (ii)) — a rescale may
  move any entry by more than `0.15` in one run; it is not exempt from the
  absolute `[0.25, 2.0]` bound.
- Every entry the rescale actually touches (i.e. every key in the
  dimension, since a geometric-mean renormalization by construction moves
  every entry unless it was already exactly at the mean) gets `updated:
  <today>` and `rationale: "rescaled <today>: dimension mean <old geomean>
  → 1.0"` (with `<old geomean>` rounded to 2 decimal places, matching the
  file's weight precision).
- **No-op:** if the dimension's current geometric mean is already within
  `±0.01` of `1.0`, the command performs no writes at all (not even an
  `updated` bump) — nothing changed, nothing to record.
- `--rescale` is **user-invoked only** — it never runs as part of the sweep
  pipeline's automatic `calibrate` step (section 1–5 above); a sweep never
  silently renormalizes a dimension on the user's behalf.
- Full-file rewrite, same envelope as section 5 (this and seeding are both
  paths through the sole-writer `calibrate.sh`, alongside the normal
  `calibrate` step — none of the three write outside `ranking-weights.json`).

### Worked example

`kinds` dimension has three entries: `friend: 1.6`, `collaborator: 1.4`,
`transactional: 1.2` (no other kinds present).

```
geomean = (1.6 * 1.4 * 1.2) ^ (1/3) = (2.688) ^ (1/3) ≈ 1.391

friend:        1.6 / 1.391 ≈ 1.15   (clamp: no-op, within bound)
collaborator:  1.4 / 1.391 ≈ 1.01
transactional: 1.2 / 1.391 ≈ 0.86
```

All three land inside `[0.25, 2.0]`, so no clamping perturbation applies
here. Each entry's `updated` becomes today's date and `rationale`:
`"rescaled 2026-08-30: dimension mean 1.39 → 1.0"`.

## Non-goals

- Does not write `wakeup.md` outcome fields (`outcome-recording.md`'s
  territory) or `profile.md` (ingestion's territory).
- Does not set the `signal-type` frontmatter field at wake-up creation time
  — the field exists on `wakeup.md` (1.1.0), but populating it consistently
  on `origin: signal` / `origin: standing` entries is plan 05/06's
  touchpoint, flagged in 2.1.
- Does not implement the tier-drift detector (plan 11 unit 10, a sibling
  spec) — a person's `tier` field is untouched by this step.
- Does not implement the profile.md-filing side of a confirmed suppression
  proposal (ingestion's territory per the single-writer table) — this step
  only creates the proposal wake-up.
