# Plan 06: Wake-up scheduler (the heartbeat)
Status: Done (2026-08-30, chunk-06-wakeup-scheduler — all 6 units; Wave C checker PASS after one doc fix (event-confirm skill re-pointed to wakeup-queue.sh); queue suite 48 green, attention 17, capacity 18. Found+fixed a BSD `date -vNd` set-vs-add bug in date arithmetic. Residual: un-debriefed mention verified by gate logic (≥3 give entries), not by a delivered mention — lands with plan 07)
Package: attention (queue/sweeps half; detection/ranking is Plan 05, same package)
Depends-on: 01; integrates 02, 04, 05 sweeps

## Objective
Build the runtime: the wake-up queue's firing mechanics and the background sweep that keeps everything current. One primitive covers "remind me this afternoon," "sync with her in a month," and every signal the scout emits — the runtime wakes when entries come due, batches coincident ones, and stays silent otherwise.

## Context
**Amended by Plan 21** (docs/plans/2026-08-29-21-calendar-intelligence.md):
`wakeup-queue.sh` absorbs the `confirm`/`decline` ops from that plan's
interim `packages/attention/scripts/proposal-confirm.sh` (which is then
retired); the sweep's fire step renders `kind: event-proposal` entries as
proposal cards (proposed event + confirm/decline affordance) and applies the
meeting-adjacency check to their firing time.

**Amended by Plan 12** (docs/plans/2026-08-29-12-cadence-capacity.md):
the single sweep schedule becomes a three-routine cadence map — `sync-sweep`
(2–3×/day), `daily-attention` (each morning after first sync), and
`weekly-planning` (Sunday evening) — defined in `docs/runtime-cloud.md`; the
planned `docs/runtime.md` content folds into `docs/runtime-cloud.md`'s
cadence section instead of a standalone file. "Overflow rolls to next
window" is now governed by the day's budget from the week-plan (see 05's
Context note). Firing gains a meeting-adjacency check (never immediately
before/after a meeting) and an explicit-wake-up exemption (`origin:
user-ask` entries always fire on their date). `weekly-planning` is a new
06-family routine, with its skill at
`packages/attention/skills/weekly-planning/`, built by plan 12.

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Wake-up queue over digests** — no fixed daily/weekly digest exists; recurring rhythms are just recurring queue entries.
- **Hybrid runtime** — on-demand sessions plus scheduled background sweeps (Claude Code scheduled agents / cron).
- **No-guilt rules** — un-debriefed meetings are mentioned once, then dropped silently; no badges, streaks, or backlog; give:ask ratio ≥3:1.
- **Capture optional and lossy-tolerant** — a sweep that finds nothing stays silent.

## Deliverables
- `packages/attention/scripts/wakeup-queue.sh` — deterministic lifecycle ops: list-due, fire (mark + emit batch artifact), snooze <duration>, dismiss <reason>; all lifecycle writes through this script, never hand-edited. Creation (`add`) is NOT here — it lives in core's `packages/core/scripts/wakeup-add.sh` so every package appends the same way (single-writer rule). **Amended by Plan 21**: also absorbs `confirm`/`decline` lifecycle ops for `kind: event-proposal` entries, per the Context note above.
- `packages/attention/skills/sweep/SKILL.md` — the background run: capture-sweep (02) → calendar-pull + calendar-reconcile (04) → filing of new inbox items (03) → signal-scan (05) → fire due wake-ups → deliver via output adapter (07)
- Scheduled-agent wiring: the schedule definition + a `docs/runtime.md` explaining cadence config and how on-demand sessions interact with the queue. **Amended by Plan 12**: the single schedule becomes the three-routine cadence map (sync-sweep/daily-attention/weekly-planning) in `docs/runtime-cloud.md`, not a standalone `docs/runtime.md` — see the Context note above.
- Batching rules: entries due within the same window fire as one delivery; overflow beyond the nudge cap rolls to next window. **Amended by Plan 12**: overflow is now governed by the day's capacity budget from the week-plan, per the Context note above.
- Snooze/dismiss feedback: writes back to the signal ranking fields (05's contract)

## Work units
Wave A (parallel):
1. [worker] `packages/attention/scripts/wakeup-queue.sh` (lifecycle ops) + `packages/core/scripts/wakeup-add.sh` (creation) — pure file ops over `wakeups/` per the contract; JSON artifact output; Bash 3.2 portable. **Amended by Plan 21**: include the absorbed `confirm`/`decline` ops for `kind: event-proposal`, per the Context note above.
2. [worker] Tests for both queue scripts: add → list-due windows, snooze moves the date, dismiss records reason, fire is idempotent (re-run doesn't double-fire).
3. [worker] `docs/runtime.md` — the runtime model: sweep cadence config, what runs scheduled vs. on-demand, the silence principle. **Amended by Plan 12**: this content folds into `docs/runtime-cloud.md`'s cadence section (three-routine map) instead of a standalone `docs/runtime.md`, per the Context note above.

Wave B (after A):
4. [worker] `packages/attention/skills/sweep/SKILL.md` — orchestrates the sub-skills in order, tolerates any of them being unbuilt (skip with a log line, so this plan can ship before 03/05 are done), fires due entries, hands the batch to the output adapter. **Amended by Plan 21**: the fire step renders `kind: event-proposal` entries as proposal cards and applies the meeting-adjacency check to their firing time, per the Context note above.
5. [worker] Scheduled-agent definition + the un-debriefed once-then-drop rule (reads 04's artifact, mentions each meeting at most once, records that it was mentioned). **Amended by Plan 12**: the schedule definition becomes the three-routine cadence map (sync-sweep/daily-attention/weekly-planning, the latter a new routine with its skill at `packages/attention/skills/weekly-planning/`), and firing gains the meeting-adjacency check plus the `origin: user-ask` explicit-wake-up exemption, per the Context note above.
6. [checker] Unattended run against fixtures: seed a due wake-up, a future wake-up, and an un-debriefed meeting; verify the due one fires once, the future one doesn't, the meeting is mentioned exactly once across two runs, and the log is clean.

## Interfaces
Consumes: wakeup contract (01); capture-sweep (02), calendar artifacts (04), signal-scan (05), debrief batch mode (03), output adapter (07) — all optional-at-runtime, skipped gracefully when absent.
Produces: the fired-batch artifact Plan 07 renders; snooze/dismiss writebacks for 05; the sweep entry point the whole system runs on.

## Proof of done
"Remind me this afternoon" fires this afternoon; a month-out entry fires in a month with its linked interaction context resurfaced; the seeded sweep runs end-to-end unattended with a clean log, fires exactly once, and stays silent on a second run with nothing due.

## Out of scope
- Push notifications to the phone (output-adapter concern, later)
- Recurring-entry authoring UI (users add recurring wake-ups by asking the agent)
- Any fixed digest
- Auto-brief generation the morning of meetings (post-v1 standing wake-up)
