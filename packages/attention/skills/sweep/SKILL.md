---
name: sweep
description: The `daily-attention` routine's entry skill — runs the sub-steps in fixed order (each tolerating an unbuilt/absent neighbour), fires due wake-ups through `wakeup-queue.sh`, applies the un-debriefed once-then-drop mention, and hands the resulting batch to an output adapter.
---

# sweep

The `daily-attention` routine from `docs/runtime-cloud.md`'s cadence map
(default: each morning, after that day's first `sync-sweep`). This skill is
the single scheduled caller of `wakeup-queue.sh fire` (per `docs/
runtime-cloud.md`'s "Queue runtime model" — on-demand chat sessions may also
call it directly, see "On-demand use" below). It ships today even though
several neighbouring steps (calendar-reconcile, the output adapter) haven't
landed yet — every step below either does its job or logs a one-line skip
and moves on, so this skill is never blocked waiting on a sibling plan.

`<store-dir>` — the private data dir (`data/store` in dev checkouts, the
cloud runtime's mounted data repo path in production). `<today>` /`<now>` —
the current date (`YYYY-MM-DD`) / timestamp (ISO 8601), overridable by the
caller (e.g. a checker running the fixture self-check below against a fixed
anchor date).

## Steps (fixed order)

### 0. Preflight

- Resolve `<store-dir>`; resolve `<today>`/`<now>`.
- Confirm the day's first `sync-sweep` has run: `docs/runtime-cloud.md`
  says `sync-sweep` "stamps `last-sweep` in the data repo on completion".
  The concrete heartbeat file/format is plan 09's scope and not yet
  finalized in this checkout — read `<store-dir>/last-sweep` if present
  (an ISO timestamp, one line) and check its date matches `<today>`. If the
  file is absent, or its date is before `<today>`, **log and continue —
  never block**: `docs/runtime-cloud.md`'s "Ordering" rule says
  `daily-attention` always runs after the morning's first sync, but this
  skill has no authority to force that sync itself, only to note when the
  precondition looks unmet.
- Regenerate `<store-dir>/signals/week-plan.json` if it's missing, or its
  `generated_at` is more than 8 days old:
  `bash packages/attention/scripts/capacity.sh <store-dir> --today <today>`.
  This is **the one place `daily-attention` may call `capacity.sh`** — per
  `docs/runtime-cloud.md`'s stale-regeneration rule, everywhere else
  (`signal-scan`, `wakeup-queue.sh fire`) treats a missing/stale week-plan
  as a fallback (`weekly_tier: normal`, `budget.max = 3`) rather than
  recomputing it themselves (single-writer rule on `week-plan.json`'s
  *scheduled* regeneration path — `weekly-planning` also writes it, on its
  own Sunday cadence, independently of this check).

### 1. Inbox filing

Invoke ingestion's `debrief` skill in batch mode
(`packages/ingestion/skills/debrief/`, "debrief batch") over
`<store-dir>/inbox/` for unfiled capture events. Per that skill's own batch
mode, run `bash packages/ingestion/scripts/triage-inbox.sh <store-dir>`
first so the ledger of deterministic junk holds is current before the
batch pass reads it. Skip with a log line if the debrief skill isn't
present in this checkout, or if there is nothing unfiled to process.

### 2. Calendar reconcile

`packages/ingestion/skills/calendar-reconcile/` (plan 04) — **UNBUILT
today** (ROADMAP row 04 "Ready"). Log `skip: calendar-reconcile not built`
and continue; step 7 below derives what it would have produced until it
lands (per `specs/undebriefed-mention.md`'s "Now (plan 04 not yet built)"
note).

### 3. Signal scan

Invoke `packages/attention/skills/signal-scan/` against `<store-dir>` for
`<today>`. Its promotions are dated ahead (`specs/ranking.md`'s due-date
table) — nothing it writes this run fires today's batch unless it happens
to already be due today.

### 4. Fire

```sh
bash packages/attention/scripts/wakeup-queue.sh <store-dir> fire --today <today> --now <now>
```

This is the only *scheduled* caller of `fire` (`docs/runtime-cloud.md`'s
"Who writes what"). Exemption (`user-ask` always fires), budget
(`signal`/`standing` gated on `week-plan.json`'s `budget.max`),
meeting-adjacency (a `--now` within `ADJACENCY_MINUTES` of a same-day timed
calendar event holds the whole run), and idempotency (an already-fired
entry is a no-op) are all specced in full in `docs/runtime-cloud.md`'s
"Queue runtime model" and `wakeup-queue.sh`'s own usage header — this step
does not restate those numbers, only invokes the script and reads its
output. Capture the batch path from stdout: a line of the form `batch:
<path>` means a batch was written; its absence (only `held-budget:`/
`held-adjacent:` lines, or no output at all) means nothing fired this run
— note "nothing fired" and continue (the batch-shaped steps below, 7 and
8, still run: step 7 may still add a `mentions`-only... no — see step 7's
gate, which requires an existing batch with ≥3 give entries, so a
nothing-fired run has no batch to attach a mention to and step 7 is
itself a no-op for this run).

### 5. Acted-on detection

```sh
bash packages/attention/scripts/wakeup-queue.sh <store-dir> acted-on [--today <today>]
```

Implements `packages/attention/specs/outcome-recording.md` §2: for every
`wakeups/*.md` entry with `fired-on` non-null and `acted-on` null, scans
`interactions/*.md` for a qualifying touchpoint (shared person, dated
inside `(fired-on, fired-on + 7 days]`) — a match writes `acted-on: true`
immediately; a fully-elapsed window with no match writes `acted-on: false`;
an open window with no match yet leaves it `null` for the next sweep
(idempotent — an already-decided entry is never touched again). This is
`wakeup-queue.sh`'s seventh op, alongside `list-due`/`fire`/`snooze`/
`dismiss`/`confirm`/`decline`; it prints `acted-on <id> -> true|false` per
entry it writes, and is silent otherwise (no output when nothing qualifies
for a decision this run).

### 6. Calibrate

```sh
bash packages/attention/scripts/calibrate.sh <store-dir>
```

(Read the script's own usage header for the exact `--window-days` flag and
default — this step passes no flags beyond `<store-dir>` unless a caller
overrides the window.) Skip with a log line if it exits non-zero — a
calibration failure must not block firing or delivery, which have already
completed by this point in the pipeline.

### 7. Un-debriefed mention

Apply `packages/attention/specs/undebriefed-mention.md` in full: derive
candidates from `<store-dir>/inbox/` `type: calendar-event` captures per
that spec's "Now (plan 04 not yet built)" section (or read plan 04's
`un-debriefed.json` directly once it exists — the rule is unchanged
either way). Grep `<store-dir>/wakeups/fired/mentioned.log` for each
candidate's `event_id` first — a match skips it permanently before any
other rule is checked.

Gate: only proceed if step 4 produced a batch (`batch: <path>` above) whose
`entries` array already has **≥3** give-kind entries — fewer, including no
batch at all, means zero mentions this run (the meeting keeps waiting,
bounded by the 14-day window). At most one mention per batch — if more than
one candidate clears the gate, pick the oldest `end.dateTime`.

On a qualifying mention: append `<event_id>\t<today>` to
`<store-dir>/wakeups/fired/mentioned.log` **first**, then add the
`mentions` array to the batch JSON via jq in-place:

```sh
jq '.mentions = [{"kind":"undebriefed-meeting","event_id":"<id>","summary":"<s>","date":"<event-date>","people":["<slug>", ...],"line":"<text>"}]' \
  <batch-path> > <batch-path>.tmp && mv <batch-path>.tmp <batch-path>
```

(the log write before the batch write, per the spec's crash-safety note —
worst case on a crash between the two is one skipped mention opportunity,
never a duplicate one).

### 8. Deliver

Hand the batch path (if any) to the output adapter. Plan 07's output
adapters are **unbuilt today** — log `deliver: batch at <path> (no adapter
yet — batch file is the delivery)` when a batch exists, or nothing at all
when step 4 produced no batch. This step never messages, never sends —
draft-never-send holds throughout (`CLAUDE.md`).

### 9. Heartbeat + exit

Stamp the `daily-attention` heartbeat — `docs/runtime-cloud.md`'s "a
routine stamps its own completion marker... distinct key" from
`last-sweep` — by writing `<now>` to `<store-dir>/last-daily-attention`
(the same one-line-ISO-timestamp convention `sync-sweep`'s `last-sweep`
file uses, per the sibling connector's `last-sweep` write). **Silence
principle:** if nothing fired in step 4 and no mention was added in step
7, the run ends with only its log lines — no message, no summary, no
digest (`docs/runtime-cloud.md`'s "Wake-up queue over digests" standing
rule).

## Run log format

One line per step, regardless of outcome:

```
step=<name> status=ok|skip|error detail=<short reason or result>
```

e.g.:

```
step=preflight status=ok detail=last-sweep today, week-plan fresh
step=inbox-filing status=skip detail=no unfiled items
step=calendar-reconcile status=skip detail=calendar-reconcile not built
step=signal-scan status=ok detail=2 promoted
step=fire status=ok detail=batch: wakeups/fired/2026-08-29T090000Z-batch.json
step=acted-on-detection status=ok detail=acted-on wu-4412 -> true
step=calibrate status=ok detail=ranking-weights.json rewritten
step=undebriefed-mention status=ok detail=1 mention added (gcal-evt-7742)
step=deliver status=ok detail=batch at wakeups/fired/2026-08-29T090000Z-batch.json (no adapter yet)
step=heartbeat status=ok detail=last-daily-attention stamped
```

## On-demand use

A chat session is not a separate code path (`docs/runtime-cloud.md`'s
"On-demand sessions"). When the user asks something like "anything for me
today?", run steps 4–5 alone against the live store — `wakeup-queue.sh
fire` followed by `wakeup-queue.sh acted-on` — without the rest of the
pipeline (no re-filing, no re-scanning, no calibration, no mention pass).
Snooze/dismiss issued from that same chat session write back through
`wakeup-queue.sh` directly, outside this skill entirely.

## Fixture self-check

```sh
# 1. Fresh scratch store
mkdir -p /tmp/sweep-check/wakeups/fired /tmp/sweep-check/inbox /tmp/sweep-check/people /tmp/sweep-check/interactions

# 2. A due wake-up (fires today) and a future one (doesn't)
bash packages/core/scripts/wakeup-add.sh /tmp/sweep-check \
  --due 2026-09-01 --person dana-whitfield --why "check in" --origin user-ask
bash packages/core/scripts/wakeup-add.sh /tmp/sweep-check \
  --due 2026-09-10 --person dana-whitfield --why "check in later" --origin user-ask

# 3. An un-debriefed meeting: a calendar-event capture 3 days before the
#    run date, a known attendee, no matching interaction on file
cat > /tmp/sweep-check/inbox/20260829T090000Z-calendar-in-calendar-abc1.md <<'EOF'
---
schema_version: 1.2.0
id: 20260829T090000Z-calendar-in-calendar-abc1
source: calendar-in/calendar
captured_at: 2026-08-29T09:00:00Z
occurred_at: 2026-08-29T15:00:00Z
type: calendar-event
participant-hints:
  - "Dana Whitfield <dana.whitfield@example.com>"
---
{
  "summary": "Coffee with Dana",
  "start": { "dateTime": "2026-08-29T15:00:00Z" },
  "end": { "dateTime": "2026-08-29T15:30:00Z" },
  "attendees": [
    { "email": "dana.whitfield@example.com", "displayName": "Dana Whitfield" }
  ]
}
EOF

# 4. First run — --today matches the due wake-up and puts the meeting
#    inside its 2-14 day un-debriefed window (run 3 days after the event)
#    (invoke this skill with --today 2026-09-01 --now 2026-09-01T12:00:00Z)

# Verify: the due (2026-09-01) wake-up fires exactly once (status: fired,
# fired-on: 2026-09-01 in wakeups/*.md); the future (2026-09-10) one stays
# status: pending; if the fired batch clears the >=3-give-entries floor,
# the meeting is mentioned exactly once (one line appended to
# wakeups/fired/mentioned.log, one entry in the batch's mentions array).

# 5. Second run, same day or later, unchanged store
#    (invoke this skill again with --today 2026-09-01 or a later date)

# Verify: the already-fired wake-up is untouched (fired-on unchanged, no
# second batch for it); the meeting is never mentioned again — its
# event_id is already in mentioned.log, so step 7 skips it before any
# other rule check; a run with nothing newly due and no new mention ends
# silently (no batch, no message) per the silence principle.
```
