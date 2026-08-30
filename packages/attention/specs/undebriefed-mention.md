# Spec: un-debriefed once-then-drop mention

Package: `attention` (plan 06, sweep delivery). Governs the sweep's one and
only touch on a past meeting that never got a debrief: mention it exactly
once, inside a batch that is already firing, then never speak of it again —
per CLAUDE.md's "Capture is optional and lossy-tolerant" and plan 06's
no-guilt rules. This is not a wake-up, not a signal, not a promotion
candidate; it never enters `wakeups/` or `wakeups/signals/` at all.

## Inputs

**Now (plan 04 not yet built):** `calendar-reconcile` and its
`un-debriefed.json` artifact don't exist yet (ROADMAP row 04 "Ready"). Until
it lands, the sweep derives un-debriefed meetings itself, deterministically,
as a `skills/sweep/SKILL.md` step slotted where the artifact will sit once
plan 04 ships. A meeting qualifies iff **all** of:

1. A `type: calendar-event` capture event sits in `<store>/inbox/`, timed
   (`start.dateTime`/`end.dateTime` present — all-day events with only
   `start.date` are out of scope).
2. Its `end.dateTime` falls strictly 2–14 days before the sweep's run date
   (inclusive both ends: `2 <= days_since_end <= 14`).
3. Its attendees resolve, by email match against `people/*.md`
   frontmatter/`participant-hints`, to **at least one** known person.
4. **No** `interactions/*.md` file has `calendar-event: <event id>`, **and**
   no interaction dated on the event's date names any resolved attendee in
   its `people` list — either would count as the debrief having happened.

**Later (plan 04 lands):** `un-debriefed.json` replaces steps 1–4 as the
input — the sweep reads its list of un-debriefed meeting records directly
instead of re-deriving them. The rule below is unchanged either way; only
the candidate source changes.

## Rule

1. **At most one mention per meeting, ever.** Once mentioned (recorded per
   rule 2), permanently done — never mentioned again on any later sweep,
   regardless of whether the user debriefed it.
2. **Record the mention as it happens.** The instant a meeting is mentioned
   in a batch, append one line to `<store>/wakeups/fired/mentioned.log`
   (append-only, attention-owned, the *sole* memory of what's been
   mentioned): `<event_id>\t<mention-date>`. Before treating any meeting as
   a candidate, grep `mentioned.log` for its `event_id` — a match skips it
   permanently, without checking any other rule below.
3. **Then silence, forever.** A later sweep never re-mentions a logged event
   id — no reminder, no escalation, no "still un-debriefed", no count. If
   the user debriefs it through any other path, nothing needs cleaning up:
   `mentioned.log` is never pruned or rewritten, only grown.
4. **Timing gate.** Never eligible on the meeting's own day or the day
   after it ends (the relationship's own time — the 2-day floor above). A
   mention rides only inside a batch already being delivered for another
   reason — a day with nothing else firing stays silent even if an eligible
   meeting exists; it waits for the next delivered batch, still within the
   14-day window. Past 14 days with no qualifying batch having fired, the
   meeting is dropped un-mentioned — never logged, never a candidate again.
5. **Give:ask ratio floor.** A batch carries at most one un-debriefed
   mention, and only if it already has **≥3** "give" entries (nudges with
   ammunition/drafts, proposal cards — the `entries` array a parallel unit
   defines) before the mention is added. Fewer than 3 give entries —
   including an empty or ask-only batch — means zero mentions; the meeting
   keeps waiting for a later batch that clears the floor, bounded by rule 4.
6. **Multiple eligible meetings.** If more than one meeting clears rules
   1–5 in the same sweep, pick the oldest `end.dateTime` (closest to aging
   out); the rest wait for a future batch.

## Batch shape

The fired-batch artifact (`wakeups/fired/<...>-batch.json`) gains one new
top-level array, `mentions`, additive alongside the `entries` array a
parallel unit defines (`entries`, `held_budget`, `held_adjacent`). Holds
zero or one object per rule 5:

```json
{
  "mentions": [
    {
      "kind": "undebriefed-meeting",
      "event_id": "gcal-evt-7742",
      "summary": "Coffee with Ayesha",
      "date": "2026-08-20",
      "people": ["ayesha-malik"],
      "line": "You met Ayesha on 2026-08-20 (Coffee with Ayesha) — want to jot anything down? No pressure."
    }
  ]
}
```

- `event_id` — the calendar capture event's id (or the id in
  `un-debriefed.json` post-plan-04); the exact string written to
  `mentioned.log`.
- `date` — the event's calendar date, used to render `line`. `mention-date`
  in `mentioned.log` is the sweep's run date (today), not `date`.
- `people` — resolved attendee slugs, bare (no `[[ ]]` wrapper).
- `line` — the exact, final user-facing text: no counts, no
  "un-debriefed" language, no urgency words, always closing with an
  explicit no-pressure clause.

The `mentioned.log` write (rule 2) happens in the same sweep step that
assembles `mentions`, and the log line is written before the batch file —
so a crash between the two writes at worst causes one skipped mention
opportunity, never a duplicate mention.

## Example scenarios

1. **Mentioned once across two runs.** Ayesha's meeting ended 2026-08-20 (5
   days before today, 2026-08-25), un-debriefed, one resolved attendee.
   Today's batch already has 4 give entries; the sweep adds it to
   `mentions` and appends `gcal-evt-7742\t2026-08-25` to `mentioned.log`.
   Tomorrow (2026-08-26), the meeting is still un-debriefed and in-window,
   but `mentioned.log` already has its event id — it's skipped, no matter
   how many give entries tomorrow's batch has.
2. **Silent day defers.** Ben's meeting ended 2026-08-18 (7 days ago),
   eligible by rules 1–4. Today's sweep has 0 give `entries` — rule 5's
   floor is unmet — so no batch delivers today and no mention happens. The
   meeting is still inside its window (through 2026-09-01); if a batch with
   ≥3 give entries fires on 2026-08-27, it's mentioned then, logged with
   that day as `mention-date`.
3. **Dropped un-mentioned past 14 days.** Walter's meeting ended 2026-08-05.
   No qualifying batch fired through 2026-08-19 (the boundary). On
   2026-08-20, `days_since_end = 15`, so the meeting no longer satisfies
   input condition 2 and silently drops out of the candidate set — never
   added to `mentions`, never logged, never reconsidered by any later
   sweep, with no trace that it was ever a candidate.

## Invariants a checker verifies

- No `event_id` appears more than once across `mentioned.log`.
- Every `event_id` in any historical `mentions` array has a corresponding
  `mentioned.log` line dated on or before that batch's date.
- No `mentions` entry's `date` is within 1 day of the batch's delivery date
  (rule 4's floor).
- No batch has more than one `mentions` entry (rule 5).
- No batch has a non-empty `mentions` array when its `entries` array has
  fewer than 3 give-kind entries (rule 5's floor).
- No `wakeups/*.md` or `wakeups/signals/*.md` file is ever created from an
  un-debriefed meeting — mentions never materialize as queue entries.
- A meeting absent from `mentioned.log` and un-debriefed >14 days with no
  interceding qualifying batch is absent from the candidate set on the next
  sweep (dropped-out, scenario 3) — never present, never logged.

## Out of scope

- Auto-generating a debrief draft/brief from the meeting — the mention is a
  single line asking, not a proposal card, and is not itself a "give" entry
  for some future batch's rule-5 floor.
- Per-meeting wake-ups or reminders — un-debriefed meetings never enter
  `wakeups/` or `wakeups/signals/`; no lifecycle, no `acted-on` tracking, no
  ranking, no calibration input. `wakeup-queue.sh`/`outcome-recording.md`
  have no jurisdiction over a mention.
- Reconciling this derivation's 14-day window against `un-debriefed.json`'s
  window once plan 04 lands — a plan 04 concern, not this spec's.
- Multi-meeting batches ("you had 3 un-debriefed meetings") — rule 6 always
  narrows to one; aggregate language is exactly the count/streak/backlog
  framing CLAUDE.md and plan 06 forbid.
