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

- Skills: `skills/signal-scan/` (the ToS-clean detector set + warmth×rarity ranking,
  ~5-nudge cap, two-signal rule), `skills/sweep/` (the background run: capture-sweep →
  calendar-reconcile → filing → signal-scan → fire due wake-ups → acted-on detection →
  calibrate → hand batch to an output adapter)
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
  `runnable-when: "05"` until the detector lands; see `evals/README.md`.

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

## Owned paths

`packages/attention/**`; at runtime: the `wakeups/` lifecycle (fire/snooze/dismiss
state, including the outcome fields) and `ranking-weights.json` in the private data
dir.

## Built by

Plans 05 (detection/ranking) and 06 (queue/sweeps) — two plans, one package.
Outcome-recording and calibration specs (plan 11, units 8–9) slot into 06's
implementation briefs verbatim.
