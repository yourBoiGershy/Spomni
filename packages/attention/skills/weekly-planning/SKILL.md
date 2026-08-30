---
name: weekly-planning
description: Sunday-evening cloud routine — pulls the data repo, runs the capacity computation over the coming week's filed calendar events, commits the fresh signals/week-plan.json, stamps its heartbeat, logs one summary line, and goes silent. Never delivers or drafts anything itself.
---

# weekly-planning

The `weekly-planning` routine from `docs/runtime-cloud.md`'s cadence map
(default: Sunday evening, `WEEKLY_PLANNING_TIME`). It is the sole writer of
`signals/week-plan.json` (`packages/core/contracts/week-plan.md`) — the
capacity model that sizes `daily-attention`'s discretionary nudge budget for
the coming week. This routine computes and commits planning state. It never
messages, nudges, or drafts anything — see the silence principle in step 6.

## 1. Resolve the store dir

The private data dir for this user — `data/store` in dev checkouts, the
cloud runtime's mounted data repo path in production. All steps below take
this as `<store-dir>`.

## 2. Sync first

Pull the data repo via store-sync (plan 09) so this run computes against the
latest filed calendar events, not a stale local copy. If the store-sync pull
script is not yet present in this checkout (plan 09 is still in progress as
of this doc), note that loudly and proceed against the local store as-is —
this is a forward-declared dependency, not a hard blocker for this routine.

## 3. Run the capacity computation

```sh
packages/attention/scripts/capacity.sh <store-dir> --today <today>
```

`<today>` is the current date (`YYYY-MM-DD`) at run time — this anchors the
7-day window (`week_start` through `week_start + 6`) the contract defines.

## 4. Failure behavior — binding

If `capacity.sh` exits non-zero:

- Write **no** partial `signals/week-plan.json`. The script itself
  guarantees this atomicity (it either writes a complete, valid file or
  leaves the existing one untouched) — this routine does not need to (and
  must not) attempt any cleanup or partial-write handling of its own.
- Log loudly: one clear error line naming the non-zero exit code, e.g.
  `weekly-planning: capacity.sh failed (exit <code>) — no week-plan written`.
- Stamp **no** heartbeat.
- Stop. Do not retry within this run, do not commit anything.

A stale week-plan with a loud failure log beats a wrong fresh one written
over a broken computation — `daily-attention`'s staleness rule (regenerate
if `generated_at` is >8 days old, per the contract) is the safety net that
recovers from a skipped week.

## 5. On success — commit and stamp

- Commit `signals/week-plan.json` to the data repo via store-sync, with a
  conventional one-line message:

  ```
  weekly-planning: week-plan <week_start> tier=<weekly_tier> budget=<min>-<max>
  ```

  (`week_start`, `weekly_tier`, `budget.min`, `budget.max` read back from the
  file `capacity.sh` just wrote.)
- Stamp the routine's completion heartbeat per `docs/runtime-cloud.md`
  (`weekly-planning`'s own completion marker — distinct key from
  `last-sweep`, per plan 09's staleness→wake-up mechanism).

## 6. Log one summary line, then end — silence principle (binding)

Log exactly one line:

```
week of <week_start>: tier <weekly_tier>, budget <min>-<max> discretionary nudges
```

Then END. This routine never messages, nudges, or drafts anything, and never
emits a digest or per-day narration beyond that single line — the week-plan
it just wrote is planning state for `daily-attention` and `05`/`06` to
consume, not a delivery in its own right (wake-up-queue-over-digests
doctrine, `docs/runtime-cloud.md`'s "Standing rules"). Draft-never-send holds
here as everywhere: this routine has no path that sends, drafts, or surfaces
anything to the user beyond the one log line above.
