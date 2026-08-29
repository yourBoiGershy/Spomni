# Plan 11: Preference & personalization layer

Status: Ready
Package: core (contracts, validator) + ingestion (stated-preference filing) +
attention (outcomes, calibration, tier drift) + connectors/composio-in (backfill mode)
Depends-on: 01 (hard). **Phase 1 must merge BEFORE plans 05/06 are implemented**
(wakeup v1.1 is cheap now, painful after). Phases 2–5 execute alongside or after
03/05/06; where those are unbuilt, this plan's units amend their briefs rather
than patching shipped code.

## Objective

Make the agent learn its user without getting smarter code: learning = state in
the data dir. Two preference kinds, mirroring provenance-labeling — **stated**
(user tells the agent: tiers, cadence wishes, signal opt-outs, priorities) and
**revealed** (observed: contact frequency, wake-up outcomes, draft edits) —
labeled separately, never mixed. Stated outranks revealed; revealed PROPOSES
changes, never silently overwrites. Every personalization artifact is a
human-readable, user-editable file, so "why did this rank high?" is always
answerable by opening two files.

## Context

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:

- **provenance-labeling** — the template for the new split: stated-by-user vs.
  observed-from-behavior, tagged per bullet, untagged = validator error.
- **attention-merge** — snooze/dismiss feedback couples ranking to firing; the
  outcome fields and calibration step land inside attention, not a new package.
- **Single-writer rule** — ingestion is sole writer of `profile.md` (stated
  preferences file like debrief facts do); attention is sole writer of wake-up
  lifecycle fields and `ranking-weights.json`. Observed proposals that belong in
  `profile.md` (style notes, tier changes) route through user confirmation and
  are then filed by ingestion — attention never writes profile.md.
- **No-guilt rules** — revealed data never scolds. Inner-circle-gone-quiet is a
  NUDGE ("reach out, or reclassify?"), never an automatic demotion; declined
  proposals are dropped silently, no re-asking on a streak.
- **code-data-separation** — weights and profile live in the user's `data/store/`;
  the repo improves only via anonymized fixtures. Personalization is per-user
  state, never machinery drift.
- **golden-tests-before-prompts** — preference filing, calibration, and tier
  drift all get input→expected-output fixtures before any prompt.

### Proposed DECISIONS.md entry (for user ratification — do NOT record until approved)

> **preference-provenance** · 2026-08-29
> Preferences carry provenance like facts do: `stated-by-user` vs.
> `observed-from-behavior`, labeled per entry, never mixed. Stated always
> outranks revealed; revealed preferences PROPOSE changes (a wake-up or chat
> prompt the user confirms) and never silently overwrite stated ones or store
> fields. All personalization state is human-readable files in the data dir
> (`profile.md`, `ranking-weights.json`), so ranking is auditable by reading.
> Why: same trust argument as provenance-labeling — behavior data is seeded
> guesswork until the user confirms it; and learning-as-data keeps the public
> machinery identical for every user.
> Revisit if: never (the stated>revealed ordering); the artifact set may grow.

### Artifact design (binding for all phases)

`data/store/profile.md` — markdown + frontmatter (`schema_version: 1.0.0`),
sole writer ingestion. Fixed sections, every bullet tagged
`**[stated-by-user]**` or `**[observed-from-behavior]**` (optional trailing
date, same convention as person.md facts; untagged = validator error):

- `## Priorities` — freeform stated priorities ("family first this quarter").
- `## Cadence wishes` — stated rhythm asks ("quarterly with the Michigan crowd").
- `## Signal opt-outs` — deterministic bullets: `<signal-type> — all` or
  `<signal-type> — [[slug]]`, signal-type from plan 05's detector set. Opt-outs
  suppress at the detector, before ranking — they are never encoded as zero
  weights.
- `## Style notes` — observed-from-behavior only, filed solely after user
  confirmation (fed by Phase 5's draft-diff loop; empty until then).

`data/store/ranking-weights.json` — sole writer attention (sweep calibration
step); follows the stats.json envelope precedent:

```json
{
  "schema_version": "1.0.0",
  "generated_at": "<ISO 8601>",
  "weights": {
    "signal-types": {"birthday": {"weight": 0.7, "updated": "2026-08-29",
      "rationale": "4 of 5 birthday nudges dismissed not-this-signal-type in 90d"}},
    "tags": {"college-friend": {"weight": 1.15, "updated": "2026-08-29",
      "rationale": "acted on 6 of 7 fired nudges"}}
  }
}
```

Absent key = neutral 1.0. Clamps: weights ∈ [0.25, 2.0], per-calibration step
≤ 0.15. Every adjustment carries a human-readable `rationale` — that string is
the interpretability contract.

**wakeup 1.0.0 → 1.1.0** (all additions optional ⇒ minor bump, per the
capture-event.md precedent; v1.0 files stay valid):

- `fired-on` (ISO date, set by attention at fire) — makes outcomes datable.
- `dismiss-reason` (enum: `not-now` | `not-this-person` | `not-this-signal-type`
  | `already-handled`) — required at dismiss time for v1.1 writers.
- `acted-on` (bool, default null) — set by the sweep: an interaction with any
  listed person dated within 7 days after `fired-on`.
- `snooze-count` (integer, default 0) — incremented per snooze, preserving the
  history today's due-rewrite discards.
- `signal-type` (kebab-case string, optional; added by the wave-F fix pass) —
  the promoting signal's type (standing entries: their standing kind), so
  calibration can bucket outcomes per signal type; absent = `unclassified`.

### Touchpoints plans 05/06 briefs MUST honor (why Phase 1 merges first)

- 05 signal-scan: apply `profile.md` Signal opt-outs before ranking; multiply
  rank by `ranking-weights.json` weights when present (neutral fallback when
  absent); create wake-ups at `schema_version: 1.1.0` with `signal-type` set
  from the detector (standing entries set their standing kind, e.g. `birthday`)
  — absent signal-type degrades calibration to an `unclassified` bucket.
- 06 wakeup-queue.sh: `dismiss` requires `--reason <enum>`; `snooze` increments
  `snooze-count` alongside the due rewrite; `fire` writes `fired-on`.
- 06 sweep: two new steps after firing — acted-on detection and calibration
  (specced by units 8–9 here); 05/06's "snooze/dismiss writeback to ranking
  fields" is realized AS `ranking-weights.json` — no parallel feedback channel.

## Deliverables

- `packages/core/contracts/profile.md` + `packages/core/contracts/ranking-weights.md`
  (shapes above, writers/readers named); wakeup.md bumped to 1.1.0;
  `packages/core/package.md` minor bump.
- `validate-store.sh` extended (profile tag/section rules, wakeup v1.1 fields)
  + fixtures + tests wired into `run-store-tests.sh`.
- Ingestion: stated-preference filing spec + goldens (utterance → profile.md /
  person.tier delta), tier-change confirmation flow.
- Attention: outcome-recording spec, `calibrate` step (outcome aggregation →
  bounded weight adjustments), tier-drift detector spec, fixtures for all three.
- Connectors: one-time backfill mode for gmail-sweep/calendar-sweep (date-range
  window, isolated checkpoint) feeding cold-start frequency via the normal
  pipeline + stats.json.
- Onboarding tiering-seed spec (backfill-informed suggestions, user confirms,
  ingestion files).
- (Optional, deferrable) draft-diff style-loop spec.

## Work units

Wave A (core contracts — parallel; **A+B must merge before 05/06 implementation**):
1. [worker] `packages/core/contracts/profile.md` per the design above +
   template + example; `packages/core/package.md` minor bump.
2. [worker] `packages/core/contracts/ranking-weights.md` per the envelope above
   (clamps, neutral-default, rationale-required rule).
3. [worker] `packages/core/contracts/wakeup.md` 1.0.0 → 1.1.0: the four optional
   fields, updated example, note that snooze now increments `snooze-count`.

Wave B (after A):
4. [worker] `validate-store.sh`: profile.md section/tag enforcement (untagged
   preference bullet = error; opt-out bullets parse deterministically), wakeup
   v1.1 optional-field validation (v1.0 files still pass).
5. [worker] Validator tests + fixtures: a fixture profile.md, wakeup fixtures at
   1.0.0 and 1.1.0 (incl. a dismissed-with-reason and an acted-on case), wired
   into `packages/core/tests/run-store-tests.sh`.

Wave C (ingestion — after A, parallel with D; if plan 03 is still unbuilt these
amend its brief, goldens land now regardless):
6. [worker] Stated-preference filing spec: how "Dana is inner-circle" in a
   debrief/voice-note files `tier` into `people/dana-whitfield.md`; how "stop
   birthday reminders" files a Signal opt-out bullet into profile.md; the
   tier-change confirmation path (attention proposal → user yes → ingestion
   files; user no → dropped silently, never re-asked).
7. [worker] Golden fixtures for unit 6: 5–6 utterances → expected profile.md /
   person.md deltas, including one ambiguous case whose expected output is a
   clarifying question, not a write.

Wave D (attention — after A, parallel with C; specs slot into 05/06 briefs):
8. [worker] Outcome-recording spec: queue lifecycle writes `fired-on` /
   `dismiss-reason` / `snooze-count`; sweep acted-on detection (7-day
   interaction window per the contract).
9. [worker] Calibration spec + `packages/attention/scripts/calibrate.sh` sketch:
   aggregate wakeups/ history (dismiss reasons, acted-on, snooze counts) →
   per-signal-type and per-tag adjustments within the clamps, rationale string
   per change; `not-this-person` feeds per-person suppression proposals, not
   global weights.
10. [worker] Tier-drift detector spec: person.tier vs. observed frequency
    (stats.json median gap) divergence → proposal wake-up (`origin: signal`);
    guardrail text verbatim: inner-circle-gone-quiet is a nudge to reach out or
    reclassify, NEVER an automatic demotion.
11. [worker] Fixtures for units 9–10: seeded wakeup histories → expected
    ranking-weights.json (with rationales); a drift scenario → expected proposal
    wake-up; a declined proposal → expected silence.

Wave E (cold start — after B):
12. [worker] Backfill mode for gmail-sweep/calendar-sweep: date-range window
    (default 12 months), separate checkpoint namespace so the one-time run never
    corrupts incremental state; test for checkpoint isolation.
13. [worker] Onboarding tiering-seed spec: backfilled interactions → stats.json
    frequency → suggested tiers presented for confirmation (never auto-set);
    confirmed tiers filed by ingestion; unconfirmed people stay untiered.

Wave F:
14. [checker] Consistency pass: contracts vs. validator vs. fixtures vs. the
    05/06 touchpoint list agree on every field name and enum value; profile tags
    survive filing goldens; single-writer table has exactly one writer per new
    artifact; report mismatches file:line.
15. [worker] Fix pass from unit 14's findings (skip if clean).

Later/optional (explicitly deferrable — does not gate Proof of done; may become
its own plan): draft-diff style loop — a sweep step matching sent messages
(read-only gmail; `draft-never-send` restricts sending, not reading own sent
mail) to fired wake-ups carrying `## Draft`, distilling edit deltas into Style
notes PROPOSALS the user confirms before ingestion files them.

## Interfaces

Consumes: person/wakeup contracts + validator (01); gmail/calendar sweeps with
date-range override (10, composio-in — plan 02's gmail-in lane is still a stub);
filing engine (03, spec-level if unbuilt); stats.json median-gap data (08).
Produces: `profile.md@1` and `ranking-weights.json@1` contracts; wakeup@1.1;
the outcome/calibration/tier-drift specs plans 05/06 implement; the backfill
mode onboarding runs once.

## Proof of done

- Wakeup 1.1.0 merged with validator + fixture coverage BEFORE any 05/06
  implementation brief is dispatched; the touchpoint list above is pasted into
  those briefs.
- A fixture profile.md with an opt-out and a stated priority passes
  `validate-store.sh`; an untagged preference bullet fails it.
- Filing goldens: each utterance produces exactly the expected delta; the
  ambiguous one produces a question, not a write.
- Calibration fixtures: seeded outcomes yield the expected weights, every
  adjustment within clamps, every change carrying a rationale a human can read.
- Tier-drift fixture yields a proposal wake-up and never a tier write; the
  declined-proposal fixture yields silence.
- Backfill run against fixture data leaves the incremental checkpoint
  byte-identical; `run-store-tests.sh` and `run-capture-tests.sh` pass.
- The preference-provenance decision text above is presented to the user for
  ratification (recorded by the orchestrator only on approval).

## Out of scope

- Editing DECISIONS.md (drafted here, user-ratified there).
- Implementing plans 05/06 themselves — this plan only fixes their contracts
  and hands them specs.
- Any automatic tier/preference mutation from observed data (permanently:
  revealed proposes, never overwrites).
- Shipping weights, profiles, or any per-user state in the repo — fixtures only.
- ML/embedding-based preference inference; the learning store is files + counts.
- Draft-diff style loop beyond the deferrable spec above.

Status: Ready
