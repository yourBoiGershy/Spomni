# Contract: week-plan

`schema_version: 1.0.0`

## Store location

`signals/week-plan.json` — one file, overwritten each run (not versioned per
week). `signals/` is created by the writer if absent.

## Writer / readers

- **Sole writer:** `packages/attention` (`scripts/capacity.sh`, run by the
  `weekly-planning` routine per plan 12,
  docs/plans/2026-08-29-12-cadence-capacity.md).
- **Readers:** `packages/attention` itself (05's ranking input, 06's firing
  budget — see amendment notes in `docs/plans/2026-08-29-05-signal-engine.md`
  and `-06-wakeup-scheduler.md`), `packages/query` (optional context for
  briefs — "how's my week looking").

## Inputs (how the writer computes this)

- Filed calendar capture events in `<store-dir>/inbox/` with frontmatter
  `type: calendar-event`, whose `occurred_at` falls within the 7-day window
  `[today, today+6]`. The body after frontmatter is JSON with
  `start.dateTime` / `end.dateTime` fields; `end.dateTime` absent → 60-minute
  default duration. All-day events (`start` is `date`-only, no `dateTime`)
  are excluded from the math entirely.
- Times are normalized to UTC epoch for computation. The working window
  defaults to `09:00`–`18:00`, parameterizable via `CAPACITY_DAY_START` /
  `CAPACITY_DAY_END`, interpreted at UTC offset `CAPACITY_TZ_OFFSET` (default
  `+00:00`).
- Per day: clip events to the working window, merge overlapping/adjacent
  events, `meeting_hours` = summed merged overlap duration,
  `largest_free_block_hours` = the longest uncovered stretch inside the
  window.

## Tier rules

### Per-day tier

| Tier | Condition |
|---|---|
| `busy` | `meeting_hours` ≥ 5 OR `largest_free_block_hours` < 2 (busy takes precedence over the other conditions below) |
| `open` | `meeting_hours` ≤ 2 (and not `busy`) |
| `normal` | anything else |

### Weekly tier

| Tier | Condition |
|---|---|
| `busy` | ≥3 days tiered `busy` |
| `open` | ≥4 days tiered `open` |
| `normal` | anything else |

## Discretionary nudge budget

| Weekly tier | Budget (nudges/week) | Selection guidance |
|---|---|---|
| `busy` | min 1, max 2 | strong/frequent ties only, low-effort messages |
| `normal` | min 2, max 3 | standard mix |
| `open` | min 3, max 5 | dormant/lesser-known ties eligible; reactivation drafts allowed |

Budget governs **discretionary (signal-originated) nudges only** — see
Exemption rule below.

## Exemption rule

Explicit user-requested wake-ups (`origin: user-ask` per `wakeup.md`) are
**exempt** from the weekly budget and tier — they always fire on their due
date regardless of the week's tier or remaining budget. Only `origin:
signal` (and, by extension, `standing`) wake-ups are governed by the budget
table above.

## Meeting-adjacency rule

No nudge — exempt or discretionary — is delivered immediately before or
right after a meeting. This is a firing-time check performed by the
consuming routine (06's firing step), not a property encoded in this
artifact and not merely a ranking preference.

## Staleness rule

A week-plan whose `generated_at` is older than 8 days is stale. Consumers
(`daily-attention`) must regenerate it (re-run `capacity.sh`) before
selecting nudges from it.

## Shape

Single JSON object, UTF-8, no trailing newline required.

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `generated_at` | ISO 8601 timestamp | yes | When `capacity.sh` ran. Drives the staleness rule. |
| `week_start` | ISO 8601 date | yes | `YYYY-MM-DD`. The `--today` the generator ran with; `days[0].date`. |
| `tz_offset` | string | yes | UTC offset used to interpret the working window, e.g. `+00:00`. Mirrors `CAPACITY_TZ_OFFSET`. |
| `working_window` | object | yes | `{"start": "HH:MM", "end": "HH:MM"}` — the working window used for this run. |
| `weekly_tier` | enum | yes | One of `busy`, `normal`, `open`. |
| `budget` | object | yes | `{"min": <int>, "max": <int>}` per the budget table above. |
| `days` | array | yes | Always exactly 7 entries, `week_start` through `week_start + 6`, in order. Zero-event days are included, not omitted. |

### `days[]` entry

| Field | Type | Required | Notes |
|---|---|---|---|
| `date` | ISO 8601 date | yes | `YYYY-MM-DD`. |
| `tier` | enum | yes | One of `busy`, `normal`, `open`. |
| `meeting_hours` | decimal | yes | Summed merged meeting overlap within the working window, ≤2 decimal places. `0` for a zero-event day. |
| `largest_free_block_hours` | decimal | yes | Longest uncovered stretch of the working window, ≤2 decimal places. Equal to the full window width for a zero-event day. |
| `events` | integer | yes | Count of calendar events contributing to this day's math (all-day events excluded). `0` for a zero-event day. |

## Example

`signals/week-plan.json`:

```json
{
  "schema_version": "1.0.0",
  "generated_at": "2026-08-30T18:00:00Z",
  "week_start": "2026-08-31",
  "tz_offset": "+00:00",
  "working_window": {"start": "09:00", "end": "18:00"},
  "weekly_tier": "normal",
  "budget": {"min": 2, "max": 3},
  "days": [
    {"date": "2026-08-31", "tier": "busy", "meeting_hours": 5.5, "largest_free_block_hours": 1.5, "events": 4},
    {"date": "2026-09-01", "tier": "normal", "meeting_hours": 3.0, "largest_free_block_hours": 3.0, "events": 2},
    {"date": "2026-09-02", "tier": "open", "meeting_hours": 1.0, "largest_free_block_hours": 6.0, "events": 1},
    {"date": "2026-09-03", "tier": "open", "meeting_hours": 0, "largest_free_block_hours": 9.0, "events": 0},
    {"date": "2026-09-04", "tier": "normal", "meeting_hours": 2.5, "largest_free_block_hours": 3.5, "events": 3},
    {"date": "2026-09-05", "tier": "open", "meeting_hours": 0.5, "largest_free_block_hours": 8.5, "events": 1},
    {"date": "2026-09-06", "tier": "normal", "meeting_hours": 2.0, "largest_free_block_hours": 4.0, "events": 2}
  ]
}
```

## Notes

- This file is *planning state*, not a delivery surface — writing it never
  sends or drafts a message on its own; it is read by 05's ranking and 06's
  firing to size and shape discretionary nudges (`wake-up-queue-over-digests`
  still holds: the queue is the only delivery mechanism).
- Single-writer rule: only `packages/attention`'s `capacity.sh` writes this
  file. `packages/query` and any other reader treats it as read-only.
- A validator can confirm shape by checking `days` has exactly 7 entries with
  contiguous dates starting at `week_start`, and that `weekly_tier` /
  `budget` are consistent with the per-day tier counts above.
</content>
