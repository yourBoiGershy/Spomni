# Capacity golden fixtures (plan 12)

Three golden fixture weeks — `open-week/`, `busy-week/`, `mixed-week/` — each a
self-contained `inbox/` of `calendar-event` capture events (per
`packages/core/contracts/capture-event.md`, schema_version 1.2.0) plus the
`expected/week-plan.json` `capacity.sh` must produce when run with
`--today 2026-08-31 --tz-offset +00:00 --working-window 09:00-18:00` against
that `inbox/`. `busy-week/` additionally carries a `wakeups/` dir seeding one
explicit user wake-up.

All three scenarios anchor to the **same week**: `--today 2026-08-31` (a
Monday) → `week_start: 2026-08-31`, week = 2026-08-31 .. 2026-09-06
(Mon..Sun). All event timestamps are UTC (`Z`). Default working window is
`09:00`–`18:00` at `tz_offset: +00:00`.

## How a test should compare

1. Run `capacity.sh` (or the equivalent week-plan builder) with
   `--today 2026-08-31` against `<scenario>/inbox/` (and, for `busy-week`,
   with `<scenario>/wakeups/` visible to whatever component checks the
   budget-exemption behavior).
2. `jq 'del(.generated_at)'` on both the actual and expected output before
   diffing — `expected/week-plan.json`'s `generated_at` is a **fixed
   placeholder** (`2026-08-31T18:00:00Z`), not the literal wall-clock
   timestamp a real run stamps. Every other field must byte-match.

## Capacity model this fixture set bakes in (per the brief; restated for the
implementer)

- Only `type: calendar-event` capture events with `occurred_at` inside the
  week window count. Duration = `end.dateTime` − `start.dateTime`; a missing
  `end` counts as **60 minutes**; an all-day event (`start.date`, no
  `dateTime`) is **excluded entirely** — not counted in `meeting_hours`, not
  counted in `events`, not overlapped against the working window.
- **`events` field definition** (not fully specified by the plan text; fixed
  here as the fixture contract): the count of qualifying (non-all-day)
  `calendar-event` capture events whose `occurred_at` date (UTC) equals that
  day — counted once per source event **before** overlap-merging, and
  regardless of whether the event's clipped-to-window overlap is zero (an
  event entirely outside 09:00–18:00 still counts as 1 in `events`, per
  `busy-week`'s day 2026-09-03, which counts its 19:00–20:30 dinner).
- Per day: clip each event to `09:00`–`18:00`, merge overlapping clipped
  intervals, sum the merged durations for `meeting_hours`; the longest
  uncovered stretch of the 9-hour window is `largest_free_block_hours`. A
  zero-qualifying-event day (including a day whose only capture event is
  all-day) is `meeting_hours: 0.0`, `largest_free_block_hours: 9.0`,
  `tier: open`, `events: 0`.
- Day tier: `busy` if `meeting_hours >= 5` **OR** `largest_free_block_hours <
  2` (busy wins over the other checks); `open` if `meeting_hours <= 2`;
  else `normal`.
- Week tier: `busy` if `>= 3` busy days (checked first — takes priority even
  if the open-day count would also qualify); else `open` if `>= 4` open days;
  else `normal`.
- Budget: `busy` → `{"min":1,"max":2}`; `normal` → `{"min":2,"max":3}`;
  `open` → `{"min":3,"max":5}`.

## Scenario tables

All times UTC. "Clipped" = each event's interval intersected with
`09:00`–`18:00` before merge; "merged" shows the union used for
`meeting_hours`.

### open-week (weekly tier: **open**, budget 3–5)

| Date | Events (clipped) | Merged | meeting_hours | largest_free_block | tier | events |
|---|---|---|---|---|---|---|
| 2026-08-31 Mon | all-day "Q3 offsite" — excluded | — | 0.0 | 9.0 | open | 0 |
| 2026-09-01 Tue | 10:00–11:00 | 10:00–11:00 | 1.0 | 09:00–10:00 (1h) vs 11:00–18:00 (7h) → 7.0 | open | 1 |
| 2026-09-02 Wed | 09:00–10:00 (missing `end`, counted 60m) | 09:00–10:00 | 1.0 | 10:00–18:00 → 8.0 | open | 1 |
| 2026-09-03 Thu | 11:00–12:30 | 11:00–12:30 | 1.5 | 09:00–11:00 (2h) vs 12:30–18:00 (5.5h) → 5.5 | open | 1 |
| 2026-09-04 Fri | 09:00–11:00 | 09:00–11:00 | 2.0 | 11:00–18:00 → 7.0 | open | 1 |
| 2026-09-05 Sat | 09:00–12:30 | 09:00–12:30 | 3.5 | 12:30–18:00 → 5.5 | normal | 1 |
| 2026-09-06 Sun | 09:00–13:00 | 09:00–13:00 | 4.0 | 13:00–18:00 → 5.0 | normal | 1 |

Open days: Mon, Tue, Wed, Thu, Fri = 5 (≥4) → weekly `open`. Pins: the
all-day-excluded rule (Mon reads as a zero-event day) and the
missing-`end`-counts-60m rule (Wed).

### busy-week (weekly tier: **busy**, budget 1–2) — wake-up seeded 2026-09-02

| Date | Events (clipped) | Merged | meeting_hours | largest_free_block | tier | events |
|---|---|---|---|---|---|---|
| 2026-08-31 Mon | 09:00–12:00, 13:00–16:00 | (unchanged, no overlap) | 6.0 | 12:00–13:00 (1h) vs 16:00–18:00 (2h) → 2.0 | busy (meeting_hours≥5) | 2 |
| 2026-09-01 Tue | 09:00–10:30, 12:00–13:30, 15:00–16:30 | (unchanged) | 4.5 | gaps 10:30–12:00, 13:30–15:00, 16:30–18:00 all 1.5h → 1.5 | busy (free_block<2, meeting_hours<5) | 3 |
| 2026-09-02 Wed | 09:00–11:00, 11:30–14:30 | (unchanged) | 5.0 | 11:00–11:30 (0.5h) vs 14:30–18:00 (3.5h) → 3.5 | busy (meeting_hours≥5) | 2 — **wake-up `2026-09-02-alex-rivera` due today** |
| 2026-09-03 Thu | 10:00–11:30 & 11:00–12:00 (overlap), 14:00–14:30, 19:00–20:30 (outside window, clips to nothing) | merge overlap → 10:00–12:00 | 2.5 (2.0 + 0.5) | 09:00–10:00 (1h), 12:00–14:00 (2h), 14:30–18:00 (3.5h) → 3.5 | normal | 4 |
| 2026-09-04 Fri | 09:00–11:30 | 09:00–11:30 | 2.5 | 11:30–18:00 → 6.5 | normal | 1 |
| 2026-09-05 Sat | none | — | 0.0 | 9.0 | open | 0 |
| 2026-09-06 Sun | none | — | 0.0 | 9.0 | open | 0 |

Busy days: Mon, Tue, Wed = 3 (≥3, checked first) → weekly `busy` even though
Sat/Sun are open. Pins: Mon/Wed isolate the `meeting_hours ≥ 5` arm of the OR;
Tue isolates the `largest_free_block < 2` arm with `meeting_hours` held below
5; Thu pins both the overlap-merge rule (two events sharing 11:00–11:30
collapse to one 2h block, not 1.5h+1h) and the outside-window clip rule (the
19:00–20:30 dinner contributes 0 to `meeting_hours` and `largest_free_block`
but still counts toward `events`, per the `events` definition above).

**Wake-up exemption**: `busy-week/wakeups/2026-09-02-alex-rivera.md` is an
`origin: user-ask` wake-up due 2026-09-02 — a `busy`-tier day inside a
`busy`-tier week with budget `{1,2}`. Fixture intent: this wake-up FIRES
despite the tight budget — explicit user-ask entries are budget-exempt (plan
12's exemption rule; the actual firing behavior is plan 06's, this fixture
only pins the exemption's precondition scenario for that suite to consume).

### mixed-week (weekly tier: **normal**, budget 2–3)

| Date | Events (clipped) | Merged | meeting_hours | largest_free_block | tier | events |
|---|---|---|---|---|---|---|
| 2026-08-31 Mon | 09:00–12:30, 13:00–15:30 | (unchanged) | 6.0 | 12:30–13:00 (0.5h) vs 15:30–18:00 (2.5h) → 2.5 | busy (meeting_hours≥5) | 2 |
| 2026-09-01 Tue | 09:00–10:30, 12:00–13:30, 15:00–16:30 | (unchanged) | 4.5 | gaps all 1.5h → 1.5 | busy (free_block<2) | 3 |
| 2026-09-02 Wed | 08:30–10:00 clipped to 09:00–10:00 | 09:00–10:00 | 1.0 | 10:00–18:00 → 8.0 | open | 1 |
| 2026-09-03 Thu | 09:00–11:00 | 09:00–11:00 | 2.0 | 11:00–18:00 → 7.0 | open | 1 |
| 2026-09-04 Fri | 09:00–12:00 | 09:00–12:00 | 3.0 | 12:00–18:00 → 6.0 | normal | 1 |
| 2026-09-05 Sat | 09:00–13:00 | 09:00–13:00 | 4.0 | 13:00–18:00 → 5.0 | normal | 1 |
| 2026-09-06 Sun | 09:00–10:00, 14:00–17:00 | (unchanged) | 4.0 | 10:00–14:00 (4h) vs 17:00–18:00 (1h) → 4.0 | normal | 2 |

2 busy (Mon, Tue) + 2 open (Wed, Thu) + 3 normal (Fri, Sat, Sun) — neither
weekly threshold (`≥3` busy, `≥4` open) is met → weekly `normal`, budget
`{2,3}`. Pins the window-straddle clip rule: Wed's event is authored
`08:30`–`10:00` in the capture event but clips to `09:00`–`10:00` (1.0h) for
capacity purposes — the raw event duration (1.5h) must never leak into
`meeting_hours`.

## Layout

```
open-week/
  inbox/*.md          7 calendar-event capture events (1 all-day, 1 missing-end)
  expected/week-plan.json

busy-week/
  inbox/*.md           12 calendar-event capture events (1 overlap pair, 1
                        outside-working-window dinner)
  wakeups/2026-09-02-alex-rivera.md   explicit user-ask wake-up, due mid-week
  expected/week-plan.json

mixed-week/
  inbox/*.md           11 calendar-event capture events (1 window-straddling)
  expected/week-plan.json
```

## Notes

- Synthetic personas only (Rosa Bennett, Marcus Webb, Priya Nair, Elena Cho,
  Tomas Berg, Nadia Fell, Owen Clarke, Alex Rivera) — never real people, per
  project doctrine.
- `captured_at` is a single sweep timestamp (`2026-08-30T08:00:00Z`, the
  Sunday before the fixture week) shared by every capture event within a
  scenario; only the trailing 4-char id suffix (`ow01`, `bw01`, `mw01`, …)
  varies, keeping ids unique within each scenario's `inbox/`.
- No `people/` or `interactions/` dirs are included — these fixtures test
  capacity/week-plan computation only, not filing or the people store.
