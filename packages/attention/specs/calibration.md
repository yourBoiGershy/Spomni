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

### 2.1 Signal-type derivation — flagged assumption, pending plan 05/06

Neither `wakeup.md` (1.1.0) nor `wakeup-add.sh` currently carries an
explicit `signal-type` field — `why` is freeform prose and `source-signal`
(when present) is an opaque id. This is a real gap this spec cannot close
unilaterally (both files are siblings' territory), so it is called out here
as the **required touchpoint for plan 05/06**: when plan 05's signal-scan
step creates a wake-up (`origin: signal` or `origin: standing`), it should
write an additional frontmatter field `signal-type: <token>` (e.g.
`birthday`, `job-change`) — additive, so a future `wakeup.md` minor bump
(1.1.0 → 1.2.0) covers it, exactly like the 1.0.0 → 1.1.0 precedent.

Until that field exists, `calibrate.sh` degrades gracefully rather than
guessing at hyphen-splitting an opaque id (person slugs themselves contain
hyphens, making any split of `source-signal` ambiguous):

- If frontmatter `signal-type` is present, use it verbatim.
- Else, every such entry (`origin: signal` or `origin: standing` with no
  `signal-type` field) is bucketed under the literal key `unclassified`, so
  the aggregate counts are never silently dropped — they show up in
  `ranking-weights.json` under `"unclassified"` with a rationale that says
  as much (see the example in section 3), which is itself a visible nudge to
  land the plan 05/06 field.
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

## Non-goals

- Does not write `wakeup.md` outcome fields (`outcome-recording.md`'s
  territory) or `profile.md` (ingestion's territory).
- Does not implement the `signal-type` frontmatter field on `wakeup.md` /
  `wakeup-add.sh` — that is plan 05/06's touchpoint, flagged in 2.1.
- Does not implement the tier-drift detector (plan 11 unit 10, a sibling
  spec) — a person's `tier` field is untouched by this step.
- Does not implement the profile.md-filing side of a confirmed suppression
  proposal (ingestion's territory per the single-writer table) — this step
  only creates the proposal wake-up.
