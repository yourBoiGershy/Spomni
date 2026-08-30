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

## Prefilter (deterministic, per kind)

Plan 30 replaces the old per-tier global cadence table with a per-**kind**
prefilter (`packages/core/contracts/relationship-scoring.md` "Kind
vocabulary" / "Drift prefilter" — this section transcribes that contract's
numbers; it is not a second source of truth for them). The prefilter is
mechanical — no judgment call — and only *narrows the candidate set*; it
never decides drift on its own.

A person is a QUIET-drift **candidate** iff **all** of:

1. `kind` (from `people/<slug>.md`, `contracts/person.md` 1.1.0) is a
   **RHYTHMED** kind — one whose soft horizon in the vocabulary table below
   is not `none`. A person with no `kind` on file is treated as
   `professional` (horizon 120) for prefilter purposes only, and the
   resulting proposal must disclose the substitution in its why-line/context
   verbatim: `"no kind on file — professional horizon assumed"`.
2. Not expired: `kind_expires` is absent, or is `>= today`. An expired kind
   (`kind_expires` in the past) never enters the prefilter — that state
   surfaces via `person.md`'s own expiry read-state, not via this detector.
3. `days_since_last` (from `packages/ingestion/scripts/derive-evidence.sh`
   output when available, else `stats.json`'s `last_interaction`) exceeds
   the kind's soft horizon (row below).

| kind | soft horizon (days) | enters prefilter? |
|---|---|---|
| `friend` | 30 | yes |
| `family` | 30 | yes |
| `collaborator` | 14 | yes |
| `professional` | 120 | yes |
| `community` | none | **no** — no-rhythm kind |
| `scheduling` | none | **no** — no-rhythm kind (also carries `kind_expires`; see rule 2) |
| `transactional` | none | **no** — no-rhythm kind |
| `unsolicited` | none | **no** — no-rhythm kind |
| `unknown` | none | **no** — no-rhythm kind |
| *(expired kind, any value)* | — | **no** — expiry check (rule 2) wins regardless of kind |

`dormant` tier is still the floor: even when a `dormant`-tagged person
clears the kind-horizon prefilter, `dormant` never quiet-drifts (unchanged
guardrail from the prior tier-based table — dormant has nowhere quieter to
go).

The horizon is a **prefilter, never a verdict and never a score** — clearing
a kind's horizon only admits a person to the judgment pass below; it does
not by itself produce a wake-up. The prior global 21/45/90-day per-tier
cadence table is **retired** — no code path or spec section computes
`median_gap_days` against a flat per-tier threshold anymore.

### UPWARD drift prefilter

Mirrors the QUIET shape: a person is an UPWARD-drift **candidate** iff their
`kind` is RHYTHMED (unkinded → `professional`, same disclosure rule) and,
in the trailing 90 days (`interactions[].date` within `[today-90, today]`),
their touchpoint count is above what their **current tier** implies — the
"implies" comparison itself is a judgment call (below), not a fixed `N` per
tier; the prefilter only requires that the raw trailing-90-day count be
non-trivially elevated for a rhythmed kind so the judgment pass has
something worth evaluating (implementation detail, not a new fixed
threshold — see `## Judgment verdict`). `inner-circle` and `close` are
still eligible for UPWARD candidacy under this shape (unlike the retired
tier table, which hard-excluded them) — the never-demote guardrail (below)
is the only asymmetry that survives.

## Judgment verdict

Every candidate that clears its direction's prefilter is handed to the
model judgment pass — the same judgment record shape defined in
`packages/core/contracts/relationship-scoring.md` "## Judgment record"
(`attention_warrant`, `suggested_tier`, `kind`, `kind_note`, `rationale`,
`confidence`; the full record also carries `kind_expires` when relevant per
that contract — reproduced by reference, not restated field-by-field here).

The judgment asks, in effect: **"has this gone quiet for this kind of
relationship, for this user?"** (QUIET direction) or the symmetric upward
question (UPWARD direction), reading:

- The candidate's evidence inputs (`## Evidence inputs`,
  `relationship-scoring.md`) — `touchpoints`, `median_gap_days`,
  `days_since_last`, `meetings`, `chat_days`, `emails`,
  `user_initiated_share`, `participation`, `co_attended`, `upcoming`,
  `talking_points`, `tier`, `kind`.
- The confirmed user model (`data/store/user-model.md`) — **draft models are
  never read**; a person whose user-model is still `status: draft` is
  judged with no user-model priors, same as if the file didn't exist.
- Priors from `ranking-weights.json`'s `kinds` and `evidence` dimensions
  (`packages/core/contracts/ranking-weights.md` 1.1.0 "Priors, not
  multipliers"), plus neighbor priors from `index/embeddings.jsonl` when
  that file exists, resolved via
  `packages/ingestion/scripts/nearest-confirmed.sh` (read-only; attention
  never writes the embeddings index).

The judgment resolves to exactly one of:

- **Quiet-drift / upward-drift proposal** — the judgment record above, with
  the full breakdown string (format: `relationship-scoring.md`'s "##
  Breakdown string" section — quoted once there; this spec does not
  re-litigate the format) attached to the resulting signal event and
  wake-up.
- **`no-drift`** — a one-line reason is logged (run log, not a store
  artifact) and no signal event is written for this person this sweep.

### UPWARD drift, judgment

Same shape as QUIET: the prefilter (above) admits rhythmed-kind candidates
with an elevated trailing-90-day touchpoint count; the judgment then decides
whether that count is actually elevated *relative to what the current tier
implies for this kind and this user* (reading the same evidence/user-model/
priors inputs) and, if so, drafts the upward-drift proposal via the same
judgment record and breakdown string. The **never-demote guardrail is
unchanged**: this detector only ever proposes moving a person to a *more*
attentive tier in the UPWARD direction — it never proposes a demotion as a
side effect of an UPWARD judgment call.

### QUIET drift, judgment

Same shape: the kind-horizon prefilter (above) admits a candidate; the
judgment reads evidence + user-model + priors and either drafts the
quiet-drift proposal or returns `no-drift`.

## Signal event

On divergence, write one `wakeups/signals/<id>.md`
(`packages/core/contracts/signal-event.md`), `type: tier-drift`:

```yaml
schema_version: 1.0.0
id: 20260830T090000Z-tier-drift-<slug>
type: tier-drift
person: ["[[<slug>]]"]
evidence: >
  kind=friend (horizon 30); days_since_last=47 (derive-evidence.sh);
  tier=close; tagged close on 2026-04-01.
confidence: medium
detected_at: 2026-08-30T09:00:00Z
```

`confidence` is the judgment record's own `confidence` field
(`relationship-scoring.md` "## Judgment record" — `low`, `medium`, or
`high`), carried verbatim from the judgment verdict into the signal event.
It is not a fixed per-detector constant: the judgment pass sets it per
candidate based on how much evidence + user-model + prior signal it had to
work with, same as any other judgment record. A `high` confidence still
requires the judgment to actually have corroborating evidence (e.g. a
confirmed user-model axis plus a clear evidence gap) — the detector does not
hand-wave `high` without that basis.

## Wake-up promotion

### UPWARD drift → proposal wake-up

`origin: signal`, `source-signal` = the signal event id above. `why` line
names the count, the kind, and current tag, e.g.:

```
why: "talked 5× this quarter (collaborator, horizon 14) but tagged dormant — bump to active?"
```

`## Context` states the proposed new tier explicitly (per the judgment's
`suggested_tier`) and links back to the signal event id, plus the breakdown
string (`relationship-scoring.md` "## Breakdown string"). No `## Draft`
section (this is a self-classification prompt, not an outreach draft).

### QUIET drift → reach-out nudge

Same wake-up shape, `origin: signal`, but the `why` line names the kind and
horizon, e.g.:

```
why: "haven't connected with [[dana-whitfield]] in 47 days (friend, horizon 30) despite close — reach out, or reclassify?"
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

The **prefilter** is fully deterministic and fixture-checkable without any
model call: given a fixture person's `kind`, `kind_expires`, and
`days_since_last` (from `derive-evidence.sh` output or `stats.json`), a
checker can hand-verify:

1. Which kind-horizon table row applies, and whether the kind is RHYTHMED.
2. Whether the expiry check passes (`kind_expires` absent or `>= today`).
3. Whether `days_since_last` exceeds the kind's horizon (QUIET), or whether
   the trailing-90-day touchpoint count is elevated for a rhythmed kind
   (UPWARD) — i.e. whether the person is admitted to the judgment pass at
   all.

The **judgment verdict** is, by design, not independently hand-computable
from a fixed table (that is the point of moving from a flat cadence table to
model judgment per plan 30) — a checker instead verifies the judgment
record's shape (all required fields present, `rationale` cites a named
evidence field and the `kind`, `confidence` is one of `low`/`medium`/`high`)
and that the breakdown string cross-references the priors it claims to have
read, per `relationship-scoring.md`'s validation rule (a rejected record is
re-judged once; on a second failure the person is left `kind: unknown` with
no tier suggestion — same rule as ingestion's judgment pass).

Suppression checks (declined-pairing, quarterly-rate-limit — below) remain
fully deterministic given a seeded `wakeups/` history in the fixture,
independent of the judgment step.

## Out of scope (per plan 05/11, amended by plan 30)

- Any tier write from this detector or from attention generally — permanent,
  per `docs/DECISIONS.md#preference-provenance`.
- `active`/`dormant` quiet-drift (dormant remains the floor; `active`
  quiet-drift still requires clearing the kind-horizon prefilter and the
  judgment pass like any other tier) — no cadence-invention beyond the kind
  vocabulary's horizons.
- Cadence-based "keep in touch every N months" reminders unrelated to a
  kind's stated horizon (plan 05 out-of-scope, carried forward: the engine
  never invents cadence reminders beyond what a person's own kind and tier
  imply).
