`wakeups/2026-08-31-theo-bramwell.md`:

```markdown
---
schema_version: 1.2.0
id: 2026-08-31-theo-bramwell
due: 2026-08-31
people: ["[[theo-bramwell]]"]
why: "scheduling intent: \"are you free for lunch next week?\" — proposed Tue 9/1 11:30am, the first lunch-length free block at least 48h out"
status: pending
origin: signal
source-signal: 20260829T090000Z-scheduling-intent-theo-bramwell
fired-on:
dismiss-reason:
acted-on:
snooze-count: 0
signal-type: scheduling-intent
kind: event-proposal
proposed-event:
  title: Lunch with Theo
  start: 2026-09-01T11:30:00-07:00
  end: 2026-09-01T12:30:00-07:00
  attendees: ["[[theo-bramwell]]"]
  location:
confirmed-on:
created-event-id:
---

## Context

Theo asked (2026-08-27, filed as `interactions/2026-08-27-theo-bramwell.md`)
whether the user is free for lunch next week — an explicit mutual ask
naming an activity and a rough timeframe, promoted from
`wakeups/signals/20260829T090000Z-scheduling-intent-theo-bramwell.md`
(confidence: high). Monday 2026-08-31 is filled by a team sync 11:00–14:00
(`interactions/2026-08-31-theo-bramwell.md`), which swallows the lunch
window entirely; Tuesday 2026-09-01 has a 10:30–14:00 gap between the
product review and the pipeline sync
(`interactions/2026-09-01-theo-bramwell.md` and
`interactions/2026-09-01-theo-bramwell--2.md`), comfortably fitting the 60m
lunch duration plus a 15-minute buffer on each side within the 11:30–13:30
lunch-class window, and well past the 48h-notice floor from detection
(2026-08-29T09:00:00Z). Earliest fitting slot: Tue 9/1, 11:30–12:30.

## Draft

Hey Theo! Would Tuesday 9/1 at 11:30 work for lunch? Would love to catch up
properly.
```

## Slot arithmetic (for a checker to recompute by hand)

- Lunch intent class: duration 60m, allowed start window 11:30–13:30, 15-min
  buffer required on each side, slot must start ≥48h after detection
  (2026-08-29T09:00:00Z).
- Monday 2026-08-31: free-block source is
  `interactions/2026-08-31-theo-bramwell.md` — busy 11:00–14:00. No gap
  anywhere inside 11:30–13:30 survives a 60m+30m (buffer) = 90m requirement,
  so Monday is fully excluded regardless of the 48h floor.
- Tuesday 2026-09-01: `interactions/2026-09-01-theo-bramwell.md` (09:00–10:30)
  and `interactions/2026-09-01-theo-bramwell--2.md` (14:00–15:30) leave a
  10:30–14:00 free block. The earliest lunch-window start (11:30) plus 60m
  (ends 12:30) plus a 15-min buffer each side (11:15–12:45) sits entirely
  inside 10:30–14:00. 2026-09-01T11:30:00-07:00 is also comfortably ≥48h
  past 2026-08-29T09:00:00Z (detection).
- No earlier qualifying day exists (Saturday/Sunday are outside the
  09:00–18:00 working window entirely in this store's convention, and
  Monday is fully booked through lunch), so Tue 9/1 11:30–12:30 is the
  unique earliest fitting slot.
