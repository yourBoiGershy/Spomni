---
name: calendar-sweep
description: Session-driven sweep of every calendar on the user's Google account via the first-party claude.ai Google Calendar connector, landing each event as a capture-event 1.2.0 file in inbox/ through normalize-capture.sh.
---

# Calendar sweep

Sweeps **every** calendar the user's Google account can see (work +
personal, per `docs/DECISIONS.md#multiple-google-calendars`) for events in a
window around "now", and lands each one as a raw capture event in
`<store-dir>/inbox/` per `packages/core/contracts/capture-event.md` (1.2.0).
This skill is **session-driven**: there is no standalone shell script that
performs the sweep end to end — the running Claude session calls the
`mcp__claude_ai_Google_Calendar__*` MCP tools directly per the steps below,
then shells out to `normalize-capture.sh` per item. Scheduling/launchd
wrapping is chunk 19's job; this skill only guarantees it is invokable as a
**single skill run** end to end.

## Read-only, hard rule

Only `list_calendars`, `list_events`, `search_events`, and `get_event` are
ever called. `create_event`, `update_event`, `delete_event`, and
`respond_to_event` are **banned** — never call them from this skill, under
any circumstance (draft-never-send; capture is read-only against the
account). `suggest_time` is part of the verified tool set but unused here.

## State this skill owns

Per `docs/data-layout.md`'s connector-runtime-state pattern, under
`data/connectors/calendar/`:

- `processed.log` — append-only dedup ledger, one line per captured event,
  keyed `<event-id>:<updated-timestamp>` (so an edited event — a changed
  `updated` field — re-captures as a **new** capture event; it is never
  treated as a duplicate of its earlier version).
- `skipped-calendars.log` — append-only log of any calendar that failed
  during a sweep run (see §3), for visibility across runs.

Create the directory before first use:

```sh
mkdir -p data/connectors/calendar
```

## 1. Enumerate calendars

Call `list_calendars` (paginate via `pageToken`/`pageSize` until no
`nextPageToken`/further page is returned) to get every calendar on the
account — this is what makes the sweep multi-calendar (work + personal +
any shared/holiday calendars), per `multiple-google-calendars`. The response
envelope:

```json
{"calendars": [
  {"id": "user@example.com", "summary": "user@example.com", "timeZone": "America/Toronto"},
  {"id": "abc123...@group.calendar.google.com", "summary": "School", "timeZone": "America/Toronto"}
]}
```

Each entry's `id` is the calendarId to pass into `list_events` below;
`description` is optional and otherwise unused by this skill.

## 2. Window

For each calendar, past 30 days / next 60 days from the sweep's own "now"
(no per-calendar checkpoint in this core — every run re-covers the same
rolling window; dedup in §5 is what prevents re-capture of unchanged
events). Compute `startTime`/`endTime` bounds once per run and reuse them
for every calendar.

## 3. Per-calendar list_events, with failure isolation

For each calendar id from §1, call `list_events` with that calendar's id and
the window from §2:

```json
{
  "accessRole": "owner",
  "defaultReminders": [{"method": "popup", "minutes": 30}],
  "events": [ ...event objects... ],
  "summary": "<calendar-owner-email>",
  "timeZone": "America/Toronto",
  "updated": "..."
}
```

Events are under the top-level `events` array. Paginate via `pageToken`
(pass the previous response's `nextPageToken`) until a response has no
`nextPageToken` — that is the last page for that calendar.

**Per-calendar failure isolation:** if a call for a given calendar id
errors (auth, not-found, rate limit, anything), log a line to
`data/connectors/calendar/skipped-calendars.log` (calendar id + timestamp +
error) and move on to the next calendar — never abort the whole sweep
because one calendar failed.

**Recurring events — VERIFY-LIVE:** `list_events` is expected to expand
recurring series into concrete in-window instances (each with its own `id`
and `start`/`end`) rather than returning the series master once, but this
has not yet been confirmed against a real recurring event on a live sweep.
Confirm on the first live run against a calendar with a recurring series
and record the finding here (replacing this paragraph) before relying on
it: if instances are NOT expanded, this skill needs an explicit instance-
expansion step added before §4; if they ARE expanded, this note can be
deleted. Do not guess in code — the live run is the check.

## 4. Per-event fields

Each event object observed live (2026-08-29, via `list_events`):

```json
{
  "id": "4m36ae4h2dn0vl6fn7qn2ug8go",
  "summary": "Tech Leaders Dinner",
  "status": "confirmed",
  "eventType": "DEFAULT",
  "location": "Arlo Wine & Restaurant",
  "htmlLink": "https://www.google.com/calendar/event?eid=...",
  "conferenceUrl": "https://meet.google.com/xxx-xxxx-xxx",
  "created": "2026-08-28T13:33:48Z",
  "updated": "2026-08-28T15:22:13Z",
  "creator":   {"email": "organizer@example.org"},
  "organizer": {"email": "organizer@example.org"},
  "start": {"dateTime": "2026-08-31T18:30:00-04:00", "timeZone": "America/Toronto"},
  "end":   {"dateTime": "2026-08-31T20:45:00-04:00", "timeZone": "America/Toronto"},
  "attendees": [
    {"email": "organizer@example.org", "organizer": true, "responseStatus": "accepted"},
    {"email": "user@example.com", "self": true, "responseStatus": "accepted"},
    {"email": "guest@example.com", "responseStatus": "needsAction"}
  ]
}
```

- `organizer`/`creator` are objects with at least `email` (no `displayName`
  observed live; treat `displayName` as optional on both).
- The organizer is also flagged inside `attendees` via `"organizer": true`
  on that attendee entry; the user's own entry carries `"self": true`.
  Neither `self` nor `organizer` flags are used to filter hints — see §6.
- `attendees[].displayName` was not present in the live sample; hints fall
  back to bare email when no name is available.
- `start`/`end` normally carry `{dateTime, timeZone}` with a UTC-offset ISO
  8601 timestamp. **Assumed, not live-verified:** all-day events use
  `{date: "YYYY-MM-DD"}` instead of `dateTime` — this shape was not observed
  on the live sweep (every sampled event was timed); handle it per §5 below,
  but treat the exact field name/form as an assumption until a live all-day
  event is captured and this note can be updated.

## 5. occurred_at

Event start normalized to UTC ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ`):

- Timed event (`start.dateTime` with a UTC offset) — convert to UTC.
- All-day event (`start.date`, assumed shape per §4) — `<date>T00:00:00Z`.

`captured_at` is the sweep run's own current UTC time (same value reused for
every item in the run, or per-item if the run is long — either is
acceptable; consistency within a run is what matters for `id` derivation).

## 6. Hints

Pipe the event object (as JSON) into `scripts/extract-hints.sh`, which
emits one `"Name <email>"`-form line per organizer, creator, and every
attendee (in that order), falling back to bare email or bare name when the
other half is missing. Duplicates across organizer/creator/attendees are
expected and left as-is (no dedup). **Never filter out the user's own
address** — a `self: true` attendee still gets a hint line; filtering the
user's own identity out of the raw capture is ingestion's job, not this
sweep's.

Pass each line as its own `--hint` to `normalize-capture.sh`.

## 7. Body + raw archive

The body is the event resource, pretty-printed as JSON (`jq .` on the raw
event object) — the provider resource itself, not a summary. Before
normalizing, compute the capture id up front (`<captured_at-compact>-
calendar-in-calendar-<4-hex-rand>`, matching `normalize-capture.sh`'s
default id form) and archive the **unmodified** per-item MCP tool output
(the raw event object exactly as returned, not the pretty-printed body) at:

```
<store-dir>/archive/raw/<capture-id>.json
```

This preserves the provenance trail across the JSON-pretty-print
transformation applied to the body.

## 8. Dedup and normalize

For each event, compute the dedup key `<event-id>:<updated-timestamp>`
(from `id` and `updated`). If that exact key is already present in
`data/connectors/calendar/processed.log`, skip the event — it was already
captured and is unchanged. Otherwise:

```sh
bash packages/connectors/scripts/normalize-capture.sh <store-dir> \
  --source calendar-in/calendar \
  --type calendar-event \
  --captured-at <run-utc-now> \
  --occurred-at <occurred-at from §5> \
  --id <capture-id from §7> \
  --hint "<hint-line>" ... \
  <<< "<pretty-printed event JSON>"
```

- **Exit 0** — the event landed in `inbox/`. Append the dedup key to
  `data/connectors/calendar/processed.log` (append-only; never edit or
  remove earlier lines).
- **Exit 1** — the item was quarantined (`inbox/quarantine/` + a reason
  file, per the normalizer's own contract). Do **not** append to
  `processed.log` — it stays eligible for a future run. Continue the sweep
  with the next event; never abort the batch, never delete anything, on a
  quarantine.

## 9. Summary

At the end of the run, report: calendars swept, calendars skipped (with
reasons, from `skipped-calendars.log`), events captured, events skipped as
already-processed, and events quarantined.

## Invocation

This skill is invokable as a single skill run over the full multi-calendar
window described above — no external scheduler is assumed or required by
this document. Recurring/periodic invocation (launchd or otherwise) is
chunk 19's job.
