# package: attention

version: 0.2.0

## Purpose

Deciding what deserves the user's attention, and when. One concern, two halves that are
deliberately not separate packages: signal detection/ranking (the scout) and the
wake-up queue lifecycle + sweeps (the heartbeat). They share the queue and a feedback
loop — snooze/dismiss outcomes tune future ranking — so splitting them would put a
package boundary through the middle of a conversation (see DECISIONS.md:
attention-merge).

## Provides

- Skills: `skills/signal-scan/` (plan 05: runs the eight-detector set — debrief-harvest,
  scheduling-intent, co-attendance, job-change, company-news, tier-drift, birthday,
  linkedin-post — in fixed order, logs `signal-event@1` candidates, ranks via
  warmth×rarity×confidence per `specs/ranking.md`, and promotes the winners into
  wake-ups under the sweep's budget/hold/two-signal rules), `skills/sweep/` (the
  `daily-attention` entry: preflight (last-sweep check, stale week-plan
  regeneration) → inbox filing (ingestion `debrief` batch) → calendar-reconcile
  (skip, plan 04 unbuilt) → signal-scan → fire due wake-ups → acted-on detection →
  calibrate → un-debriefed mention → deliver via connectors' `deliver-tick.sh`
  (plan 33) → heartbeat; every step skips-with-log if its dependency is unbuilt/absent),
  `skills/weekly-planning/` (the Sunday routine: store-sync pull → `scripts/capacity.sh`
  → commit week-plan; per plan 12 cadence-capacity)
- `specs/` (plan 05 detector/ranking specs): `ranking.md` (score formula,
  capacity-mode inversion, two-signal rule, suppression floor, budget/hold, due-date
  table, ammunition assembly — the single source of truth every detector spec cites),
  plus the detector specs `debrief-harvest.md`, `scheduling-intent.md`, `birthday.md`,
  `co-attendance.md`, `job-change.md`, `company-news.md`, `tier-drift.md` (confidence
  rubrics, evidence format, opt-out/dedup mechanics, due-date rule per type);
  `undebriefed-mention.md` (plan 06: the sweep's once-then-drop mention of a
  past un-debriefed meeting — candidate derivation, `mentioned.log`, the
  ≥3-give-entries gate, the 14-day drop-out)
- `scripts/learn-sweep.sh` — deterministic, no-model sync-tick: walks a
  line-count cursor over `signals/feedback.jsonl`, turns new corrections
  into learned regression eval cases via ingestion's
  `feedback-to-evals.sh`, and holds disputed (conflicting) corrections for
  the user instead of auto-resolving them (plan 36 D). Sole writer of
  `<data-dir>/attention/learn-sweep.cursor` and
  `<data-dir>/attention/learn-conflicts.tsv`; scheduled as the `learn`
  sync lane; prints a 3-line digest; never writes user-model.md.
- `scripts/staleness.sh` — the deterministic staleness check the `sweep` skill
  calls: reads routine heartbeats (`heartbeats/<routine>.json`, `heartbeat@1.0.0`)
  and connector-lane scheduler state (`<sync-data-dir>/connectors/sync-scheduler/`)
  and creates exactly one pending wake-up (`origin: standing`,
  `source-signal: staleness:<name>`, `signal-type: staleness`) per subject
  that has gone quiet for more than 2x its cadence, deduped against any
  already-pending or fired-unresolved entry for that same signal
- `scripts/capacity.sh` — deterministic week-plan writer per
  `packages/core/contracts/week-plan.md`, sole writer of `signals/week-plan.json`,
  per plan 12 cadence-capacity (docs/plans/2026-08-29-12-cadence-capacity.md)
- Queue lifecycle: `scripts/wakeup-queue.sh` — all seven ops over
  `wakeups/*.md` (creation stays with core's `wakeup-add.sh` so any package
  may append): `list-due` (pending, due <= today), `fire` (budget + meeting-
  adjacency gated; writes `status: fired`/`fired-on` and emits one batch
  artifact at `wakeups/fired/<today>T<HHMMSS>Z-batch.json` — entries carry
  id/due/people/why/origin/kind/signal_type/context/draft/proposed_event,
  plus `held_budget`/`held_adjacent` id lists), `snooze`, `dismiss`, the
  event-proposal `confirm <id> --event-id <id>` / `decline <id> --reason
  <enum>` ops absorbed from the retired `proposal-confirm.sh` per plan 21's
  amendment to plan 06, and `acted-on` (the sweep's acted-on detection step,
  `specs/outcome-recording.md` §2: writes `acted-on: true` on a matching
  filed interaction within 7 days of `fired-on`, `false` once that window
  closes with no match, else leaves it `null`). Budget: `origin: signal|standing` entries fire only
  while `fired_this_week < budget.max` from `signals/week-plan.json`
  (missing/stale >8 days falls back to `budget.max = 3`, WARN);
  `origin: user-ask` is exempt. Adjacency: a `--now` within 30 minutes
  (default) of a same-day timed calendar event holds the entire run.
- Outcome recording: `fired-on`/`dismiss-reason`/`snooze-count`/`acted-on` writes on
  `wakeups/*.md` per `specs/outcome-recording.md` (sole writer of the wakeup lifecycle
  fields, per `wakeup.md`'s writer table and `docs/DECISIONS.md#attention-merge`)
- `ranking-weights@1.1` (`ranking-weights.json`) — `scripts/calibrate.sh` is its sole
  writer, three modes: ordinary sweep mode aggregates `wakeups/` outcome history into
  bounded per-signal-type and per-tag adjustments (calibration mechanics specced by a
  sibling unit, not this file), carrying `kinds`/`evidence` forward unchanged;
  `--seed-from-user-model` seeds `kinds`/`evidence` from `user-model.md` when
  `status` is `confirmed` or `provisional` (`specs/calibration.md` "Seeding
  from user-model"; plan 31 D6); `--rescale
  <dimension>` geometric-mean renormalizes one dimension in place (`specs/
  calibration.md` "Rescale"). The latter two are user-invoked only, never part of
  the sweep pipeline.
- `skills/signal-scan/`'s `tier-drift` step (plan 30, `specs/tier-drift.md`): a
  deterministic per-kind horizon prefilter (rhythmed kinds only, unkinded ->
  `professional`, expired kinds excluded) narrows candidates, then a model judgment
  pass (`relationship-scoring.md`'s judgment record) verdicts each candidate into a
  quiet-drift/upward-drift proposal (full breakdown string) or `no-drift` — replacing
  the retired flat 21/45/90-day per-tier cadence table.
- The fired-batch artifact `query`/output adapters render; snooze/dismiss writebacks
- `evals/` (`packages/attention/evals/`) — T3 skill-tier eval cases per
  `packages/core/contracts/eval-case.md`, wrapping
  `tests/fixtures/tier-drift-upward` and `tests/fixtures/declined-proposal`
  to pin the tier-drift detector's never-demote and silence-on-decline
  guardrails (`specs/tier-drift.md`) as executable graders. Both cases carry
  `runnable-when: "06"` — the detector itself landed with plan 05, but the
  cases wait on plan 06's sweep wiring to expose it as a `claude -p` skill
  invocation; see `evals/README.md`.

## Consumes

- `feedback-event@^1` (core) — `scripts/wakeup-queue.sh`'s `fire`/`snooze`/
  `dismiss`/`confirm`/`decline` lifecycle ops each append one
  `feedback-event@1` line via ingestion's `scripts/feedback-file.sh`
  (sanctioned cross-package call, plan 34 D1); a missing `feedback-file.sh`
  is skip-with-log, never an error. Attention never opens
  `signals/feedback.jsonl` for write — ingestion is its sole writer.
- `feedback-event@^1` (core), read side — the `tier-drift` judgment pass
  and `signal-scan`'s draft composition step read the ledger read-only via
  ingestion's `packages/ingestion/scripts/feedback-recent.sh` (`##
  Recent corrections` / `## Recent draft edits` blocks); attention never
  reads `signals/feedback.jsonl` directly. `scripts/learn-sweep.sh` is the
  one exception: it reads `signals/feedback.jsonl` read-only for its
  cursor walk, then calls ingestion's `scripts/feedback-to-evals.sh` to
  turn new corrections into eval cases (sanctioned cross-package call,
  mirroring the `feedback-file.sh` precedent above) — attention never
  writes the ledger or the eval cases itself.
- `signal-event@^1`, `wakeup@1.2` (core) — outcome recording targets the 1.1 fields
  specifically (`fired-on`, `dismiss-reason`, `acted-on`, `snooze-count`); a 1.0 file
  is upgraded to 1.1 in place the first time a 1.1 writer (`wakeup-queue.sh`
  fire/snooze/dismiss) touches it. `wakeup-queue.sh`'s `confirm`/`decline` ops
  target the 1.2 fields (`confirmed-on`, `created-event-id`) on
  `kind: event-proposal` entries specifically
- `profile@1` (core) — signal-scan applies `## Signal opt-outs` before ranking;
  calibration reads style-note context. Read-only: attention never writes `profile.md`
  (revealed preferences propose via a wake-up, they never overwrite stated ones)
- `interaction@1` (core) — acted-on detection scans `interactions/*.md` for a
  qualifying touchpoint (shared `people` entry, dated within the 7-day
  post-`fired-on` window) per `specs/outcome-recording.md`
- Typed `linkedin-notification`/`event-confirmation` events (connectors/gmail-in),
  contact artifacts (connectors/contacts-in), `same-event-as` links and calendar
  artifacts (ingestion), `needs-follow-up` markers (ingestion)
- Calendar `calendar-event` capture events (connectors/calendar-in) — `scripts/capacity.sh`'s
  input for computing `signals/week-plan.json` (`week-plan@1` is provided by this
  package, not consumed)
- `week-plan@1` (`signals/week-plan.json`) — provided by this package's own
  `scripts/capacity.sh`/`weekly-planning` routine, and read back by `skills/signal-scan/`
  for the capacity-mode warmth inversion and the budget/hold decision
  (`specs/ranking.md` §2/§8); same-package read, no cross-package consume needed.
  A missing/stale (>8 days) file is treated as `weekly_tier: normal`,
  `budget.max = 3` and logged, never recomputed by signal-scan itself.
- `ranking-weights@^1.1` (`ranking-weights.json`) — read by `skills/signal-scan/` as
  the per-signal-type/per-tag score multiplier (`specs/ranking.md` §5) and by the
  `tier-drift` step's judgment pass as the `kinds`/`evidence` prior-strength hints
  (`specs/tier-drift.md` "## Judgment verdict",
  `packages/core/contracts/ranking-weights.md` 1.1.0); `scripts/calibrate.sh` is its
  sole writer (see above), so this is also a same-package read, not a cross-package
  consume.
- `user-model@^1` (core) — read-only, **confirmed only**: the `tier-drift` judgment
  pass reads `data/store/user-model.md` for its axis/protected-time priors when
  `status: confirmed` (absent or `status: draft` → judge without user-model priors,
  disclosed as `user-model: none` in the breakdown string; provisional is also
  treated as not-yet-confirmed here — the drift judgment keeps the stricter
  gate); `scripts/calibrate.sh --seed-from-user-model` reads it to seed
  `ranking-weights.json`'s `kinds`/`evidence` dimensions, accepting `confirmed`
  or `provisional` and refusing (exit 3) on anything else (plan 31 D6).
  Attention never writes `user-model.md`.
- `relationship-scoring@^1` (core) — the kind vocabulary, judgment record shape, and
  breakdown-string format the `tier-drift` step's prefilter and judgment pass
  transcribe from and produce, per `specs/tier-drift.md`.
- `embeddings-index@^1` (core) — read-only, via ingestion's
  `packages/ingestion/scripts/nearest-confirmed.sh`: the `tier-drift` judgment pass's
  neighbor priors when `index/embeddings.jsonl` exists (omitted, not blocking,
  when absent).
- `person@^1.1` (core) — the `kind`/`kind_note`/`kind_source`/`kind_expires`/
  `kind_updated` columns (1.1.0 addition) the `tier-drift` prefilter reads per person,
  alongside the pre-1.1.0 `tier` field.
- `nudge-card@^1` (core) — the shape `wakeup-queue.sh fire` writes into each fired
  batch's `entries` array; connectors' `deliver-tick.sh` (plan 33) is the reader that
  renders it for delivery.
- `profile@^1.1` (core) — read-only, `## Notify` section: the sweep's deliver step
  (step 8) does not read this itself, but hands off to `deliver-tick.sh`, which
  resolves the delivery channel from it (default `beeper-self`, fallback
  `gmail-self`); listed here because the sweep is the caller.
- `heartbeat@1.0.0` (core, `packages/core/contracts/heartbeat.md`) — the sweep's
  step 9 and `weekly-planning`'s success/failure steps are its sole producers here,
  each calling `packages/core/scripts/heartbeat-stamp.sh` (creation-only, one
  sanctioned writer per routine); `scripts/staleness.sh` is the sole reader,
  consuming `heartbeats/<routine>.json` to notice a routine that has gone
  silent past 2× its cadence.
- `packages/core/scripts/store-sync.sh` (core) — `weekly-planning`'s step 5 uses
  its `commit`/`push` subcommands to land `signals/week-plan.json`; same
  sanctioned entry point every runtime uses against a git-backed store.

## Owned paths

`packages/attention/**`; at runtime: the `wakeups/` lifecycle (fire/snooze/dismiss
state, including the outcome fields), `wakeups/fired/` (fire batch artifacts —
stays attention-owned even after delivery; `deliver-tick.sh` only reads it),
`ranking-weights.json`, `signals/week-plan.json`, and `<data-dir>/attention/`
(the `learn-sweep.sh` cursor + conflicts file) in the private data dir.
`outbox/` (including `outbox/delivered.log`) is connectors-owned, not attention's
— see `packages/connectors/package.md` (plan 33).

## Built by

Plans 05 (detection/ranking) and 06 (queue/sweeps) — two plans, one package.
Outcome-recording and calibration specs (plan 11, units 8–9) slot into 06's
implementation briefs verbatim. Plan 05's detection/ranking landed:
`skills/signal-scan/` plus `specs/ranking.md` and the five new detector specs
(`docs/plans/2026-08-29-05-signal-engine.md`); the tier-drift/declined-proposal
evals flip to `runnable-when: "06"` pending the sweep wiring that invokes it.
Plan 06 (queue/sweeps) landed: `scripts/wakeup-queue.sh`,
`specs/outcome-recording.md`, `specs/undebriefed-mention.md`, and
`skills/sweep/` — the `daily-attention` entry skill that wires signal-scan,
`wakeup-queue.sh fire`, acted-on detection, `calibrate.sh`, and the
un-debriefed mention into one ordered, skip-tolerant sweep
(`docs/plans/2026-08-29-06-wakeup-scheduler.md`). Plan 30 (units 16–17)
made the semantic-scoring/user-model model operative here: `tier-drift`'s
retired flat cadence table replaced by the kind-horizon prefilter + model
judgment procedure, and `calibrate.sh` gained `--seed-from-user-model`/
`--rescale` alongside carrying `ranking-weights.json`'s `kinds`/`evidence`
dimensions through ordinary sweep runs at schema 1.1.0.
