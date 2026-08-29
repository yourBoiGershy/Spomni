# Spec: tier-drift detector

Package: `attention` (plan 05 detector set, added by plan 11 unit 10).
Signal `type`: `tier-drift`. Writes only `wakeups/signals/<id>.md` (via the
normal signal-scan path) and, when promoted, a `wakeups/<id>.md` proposal —
**never** `people/<slug>.md`. Tier changes are filed exclusively by
`packages/ingestion`, only after the user confirms
(`docs/DECISIONS.md#preference-provenance`: revealed proposes, never
overwrites).

## Inputs

Per sweep, for every person with a `tier` set in `people/<slug>.md`
frontmatter (`packages/core/contracts/person.md`):

- `tier` — one of `inner-circle`, `close`, `active`, `dormant`.
- `stats.json` (`packages/core/contracts/derived-index.md`) rollup for that
  slug: `median_gap_days`, `touchpoints`, `interactions[].date` (sorted
  newest-first). The detector reads the pre-generated `stats.json`; it never
  recomputes gaps itself.
- `data/store/profile.md` `## Signal opt-outs` section (opt-out check, below).
- Prior `wakeups/*.md` history for the person (rate limit + declined-pairing
  suppression, below).

## Expected-cadence table (per tier)

Defines what "on cadence" means for the QUIET-drift direction. A tier is
quiet-drifting when the person's `median_gap_days` from `stats.json` exceeds
the tier's threshold, **and** the most recent interaction (`interactions[0].date`)
is at least that many days before the sweep's run date (avoids firing off a
stale median right after a catch-up).

| Tier | Expected max gap (days) | Quiet-drift threshold |
|---|---|---|
| `inner-circle` | 21 | `median_gap_days` > 35 (i.e. > ~5 weeks) |
| `close` | 45 | `median_gap_days` > 75 |
| `active` | 90 | `median_gap_days` > 150 |
| `dormant` | n/a | quiet-drift never fires for `dormant` (already the floor) |

Only `inner-circle` and `close` produce a QUIET-drift nudge (per the brief:
"QUIET drift for inner-circle/close"). `active` quiet-drift and `dormant`
quiet-drift are out of scope for this detector — no cadence-invention per
plan 05's out-of-scope list.

## Divergence definitions

### UPWARD drift (contact more frequent than tier implies)

Fires when **both**:

1. `tier` is `dormant` or `active`, and
2. In the trailing 90 days (`interactions[].date` within `[today-90, today]`),
   the touchpoint count is `>= N` for the current tier:
   - `dormant` → `N = 3`
   - `active` → `N = 6` (i.e. roughly twice the `active` expected cadence of
     one per ~45 days)

Concrete example (matches the brief's why-line): a person tagged `dormant`
with 5 interactions in the trailing 90 days triggers UPWARD drift.

`inner-circle` and `close` never trigger UPWARD drift — there is no tier
above `inner-circle` to bump into, and `close` bumping to `inner-circle` on
frequency alone is judgment the detector should not make unprompted; it's
covered by the general "seems closer than tagged" case being left to the
user via the same UPWARD math applied only at `dormant`/`active` per this
spec (do not extend without a fixture proving the `close`→`inner-circle`
case behaves sanely).

### QUIET drift (contact quieter than tier implies)

Fires when **both**:

1. `tier` is `inner-circle` or `close`, and
2. `median_gap_days` exceeds that tier's quiet-drift threshold in the table
   above, and the most recent interaction is at least that many days old
   (see table note).

## Signal event

On divergence, write one `wakeups/signals/<id>.md`
(`packages/core/contracts/signal-event.md`), `type: tier-drift`:

```yaml
schema_version: 1.0.0
id: 20260829T090000Z-tier-drift-<slug>
type: tier-drift
person: ["[[<slug>]]"]
evidence: >
  tier=dormant; 5 interactions in trailing 90 days (stats.json
  touchpoints, median_gap_days=12); tagged dormant on 2026-04-01.
confidence: medium
detected_at: 2026-08-29T09:00:00Z
```

`confidence` is always `medium` for this detector (single-source: internal
interaction counts, not corroborated by a second independent signal per the
two-signal rule) unless a fixture later demonstrates a case warranting `high`
— do not hand-wave a `high` confidence without that evidence.

## Wake-up promotion

### UPWARD drift → proposal wake-up

`origin: signal`, `source-signal` = the signal event id above. `why` line
names the count and current tag, e.g.:

```
why: "talked 5× this quarter but tagged dormant — bump to active?"
```

`## Context` states the proposed new tier explicitly (`dormant` → `active`;
`active` → `close` is NOT proposed by this detector's `N` thresholds above —
only the one-step bump the trailing-90-day math actually supports) and links
back to the signal event id. No `## Draft` section (this is a
self-classification prompt, not an outreach draft).

### QUIET drift (inner-circle/close) → reach-out nudge

Same wake-up shape, `origin: signal`, but the `why` line frames it as the
brief specifies:

```
why: "haven't connected with [[dana-whitfield]] in 11 weeks despite inner-circle — reach out, or reclassify?"
```

**Guardrail (verbatim, binding):**

> Inner-circle-gone-quiet is a nudge to reach out or reclassify, NEVER an
> automatic demotion.

This detector MUST NOT propose a tier write in the QUIET direction — the
proposal offers two paths (reach out; or reclassify to a quieter tier) and
lets the user pick either, or neither, via the confirmation path below. No
code path in this detector or the promotion step writes `tier` under any
circumstance.

## Confirmation path (both directions)

1. User replies/acts affirmatively (e.g. "yes, bump her to active", "yes,
   reclassify to close") on the fired wake-up (via query/chat surface, out of
   this spec's scope) → attention hands the confirmed `(slug, new-tier)` pair
   to ingestion; ingestion (sole writer of `person.md`) files `tier` into
   `people/<slug>.md`. Attention itself never writes `tier`.
2. User declines, ignores, or the wake-up is dismissed with
   `dismiss-reason: not-this-signal-type` → the proposal is dropped silently.
   No new artifact is created to record the decline (the brief: "track via
   the dismissed wakeup itself ... no new artifact") — the dismissed
   `wakeups/<id>.md` file, with its `dismiss-reason`, IS the record.
3. **Declined-pairing suppression:** before emitting a new UPWARD or QUIET
   proposal for a `(person, proposed-tier)` pair, the detector scans existing
   `wakeups/*.md` for an entry where `people` includes the slug, `origin:
   signal`, `source-signal` points at a `type: tier-drift` signal event
   proposing that same `proposed-tier` (recorded in that wake-up's
   `## Context`), `status: dismissed`, and `dismiss-reason:
   not-this-signal-type`. If `fired-on` (or the dismissal date if
   `fired-on` is absent) is within 180 days of today, suppress — do not
   re-propose that exact `(person, proposed-tier)` pair. A *different*
   proposed-tier for the same person (e.g. declined `active`, later
   qualifies for `close`) is not suppressed by this rule.

## Rate limit

At most **one** tier-drift proposal wake-up per person per quarter (90-day
rolling window), regardless of direction or how many times the divergence
re-triggers within that window. Implementation: before emitting, scan
`wakeups/*.md` for any prior `origin: signal` entry whose `source-signal`
resolves to a `type: tier-drift` signal event naming this person, with
`detected_at` (or the wake-up's own creation, if that's unavailable) within
the last 90 days. If found, suppress this sweep's candidate regardless of
outcome (fired, pending, snoozed, or dismissed) — the quarterly cap is on
*proposing*, not on outcome.

## No-guilt guardrail

Per `CLAUDE.md` standing principles and plan 11's no-guilt rule: a QUIET
drift produces **one** nudge per the rate limit above, never accumulating
pressure across sweeps. Re-triggering the same underlying gap within the
90-day window is expected and must not surface as a second, third, or
escalating nudge — the rate limit above is the enforcement mechanism, and no
separate "days overdue" counter or streak framing is ever added to the
why-line or `## Context`.

## Opt-outs

Before evaluating either direction for a person, check
`data/store/profile.md` `## Signal opt-outs`
(`packages/core/contracts/profile.md`) for:

- `tier-drift — all` → suppress this detector for every person, sweep-wide.
- `tier-drift — [[slug]]` → suppress this detector for that person only.

Opt-outs suppress before signal-event emission (no `wakeups/signals/` entry
is written at all for an opted-out person), matching plan 05/11's rule that
opt-outs act at the detector, never as a `ranking-weights.json` zero weight.

## Deterministic fixture-checkability

Given a fixture person's frontmatter `tier` plus a fixture `stats.json`
rollup (`touchpoints`, `median_gap_days`, `interactions[].date`) and a sweep
run-date, a checker can hand-verify:

1. Which table row/threshold applies.
2. Whether the UPWARD or QUIET condition's boolean expression evaluates true.
3. The exact `why` line and proposed tier the promotion step should produce.
4. Whether the declined-pairing or quarterly-rate-limit suppression should
   apply, given a seeded `wakeups/` history in the fixture.

No field in this spec depends on judgment calls outside the tables and
thresholds above — a `close` person with `median_gap_days: 80` and a
last-interaction 90 days ago is unambiguously QUIET-drifting (80 > 75
threshold from the table); a `dormant` person with 2 interactions in the
trailing 90 days is unambiguously NOT UPWARD-drifting (2 < 3 threshold).

## Out of scope (per plan 05/11)

- Any tier write from this detector or from attention generally — permanent,
  per `docs/DECISIONS.md#preference-provenance`.
- `active`/`dormant` quiet-drift, and any `close`→`inner-circle` UPWARD case
  not covered by the trailing-90-day thresholds above — extend only with a
  fixture proving the behavior.
- Cadence-based "keep in touch every N months" reminders unrelated to a
  tier's stated meaning (plan 05 out-of-scope: the engine never invents
  cadence reminders beyond what a person's own tier implies).
