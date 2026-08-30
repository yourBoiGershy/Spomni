# package: attention

version: 0.1.0

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
  background run: capture-sweep → calendar-reconcile → filing → signal-scan → fire due
  wake-ups → acted-on detection → calibrate → hand batch to an output adapter),
  `skills/weekly-planning/` (the Sunday routine: store-sync pull → `scripts/capacity.sh`
  → commit week-plan; per plan 12 cadence-capacity)
- `specs/` (plan 05 detector/ranking specs): `ranking.md` (score formula,
  capacity-mode inversion, two-signal rule, suppression floor, budget/hold, due-date
  table, ammunition assembly — the single source of truth every detector spec cites),
  plus the detector specs `debrief-harvest.md`, `scheduling-intent.md`, `birthday.md`,
  `co-attendance.md`, `job-change.md`, `company-news.md`, `tier-drift.md` (confidence
  rubrics, evidence format, opt-out/dedup mechanics, due-date rule per type)
- `scripts/capacity.sh` — deterministic week-plan writer per
  `packages/core/contracts/week-plan.md`, sole writer of `signals/week-plan.json`,
  per plan 12 cadence-capacity (docs/plans/2026-08-29-12-cadence-capacity.md)
- Queue lifecycle: `scripts/wakeup-queue.sh` (list-due, fire, snooze, dismiss —
  creation stays with core's `wakeup-add.sh` so any package may append)
- Event-proposal confirm/decline lifecycle: `scripts/proposal-confirm.sh`
  (interim — plan 21's `confirm <id> --event-id <id>` / `decline <id>
  --reason <enum>` ops on `kind: event-proposal` wake-ups; absorbed by
  `scripts/wakeup-queue.sh` once plan 06 lands, per plan 21's amendment to
  plan 06)
- Outcome recording: `fired-on`/`dismiss-reason`/`snooze-count`/`acted-on` writes on
  `wakeups/*.md` per `specs/outcome-recording.md` (sole writer of the wakeup lifecycle
  fields, per `wakeup.md`'s writer table and `docs/DECISIONS.md#attention-merge`)
- `ranking-weights@1` (`ranking-weights.json`) — the sweep's `calibrate` step is its
  sole writer; aggregates `wakeups/` outcome history into bounded per-signal-type and
  per-tag adjustments (calibration mechanics specced by a sibling unit, not this file)
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

- `signal-event@^1`, `wakeup@1.2` (core) — outcome recording targets the 1.1 fields
  specifically (`fired-on`, `dismiss-reason`, `acted-on`, `snooze-count`); a 1.0 file
  is upgraded to 1.1 in place the first time a 1.1 writer (dismiss) touches it.
  `scripts/proposal-confirm.sh` targets the 1.2 fields (`confirmed-on`,
  `created-event-id`) on `kind: event-proposal` entries specifically
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
- `ranking-weights@1` (`ranking-weights.json`) — read by `skills/signal-scan/` as the
  per-signal-type/per-tag score multiplier (`specs/ranking.md` §5); this package's own
  sweep `calibrate` step is its sole writer (see above), so this is also a same-package
  read, not a cross-package consume.

## Owned paths

`packages/attention/**`; at runtime: the `wakeups/` lifecycle (fire/snooze/dismiss
state, including the outcome fields), `ranking-weights.json`, and `signals/week-plan.json`
in the private data dir.

## Built by

Plans 05 (detection/ranking) and 06 (queue/sweeps) — two plans, one package.
Outcome-recording and calibration specs (plan 11, units 8–9) slot into 06's
implementation briefs verbatim. Plan 05's detection/ranking landed:
`skills/signal-scan/` plus `specs/ranking.md` and the five new detector specs
(`docs/plans/2026-08-29-05-signal-engine.md`); the tier-drift/declined-proposal
evals flip to `runnable-when: "06"` pending the sweep wiring that invokes it.
