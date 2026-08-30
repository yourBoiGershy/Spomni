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
the window from §2, requesting the **maximum `pageSize` the tool accepts** —
per `packages/core/contracts/import-pipeline.md` D5 (fetch-to-file), a large
enough page pushes the result past the harness inline threshold so it lands
on disk as a saved tool-result file instead of model context. **Verify the
accepted maximum in Step-0 style, don't guess:** on the first `list_events`
call of a run, request a high value (e.g. 2500) and read back the actual
page size the tool honored from the response/tool-result metadata; if the
tool caps it lower, use the observed cap for the remainder of the run. Note
the saved-file path the harness reports for each page — every per-event step
in §4–§8 below reads from that saved page file via jq, never from inline
model context.

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
`nextPageToken` — that is the last page for that calendar; pagination
mechanics are unchanged by the fetch-to-file mechanism above, each page just
independently lands on disk (or, on the small-page residual, is captured per
the inline-residual rule in §7).

**Empty calendar — live-verified 2026-08-29:** a calendar with no events in
the window returns an envelope with **no `events` key at all** (not an empty
array), e.g. `{"accessRole":"owner","summary":"School","timeZone":"America/Toronto","updated":"..."}`.
This is a valid no-results state, not an error — iterate `.events[]?` (or
equivalent null-safe access) rather than assuming `events` is always present.

**Per-calendar failure isolation:** if a call for a given calendar id
errors (auth, not-found, rate limit, anything), log a line to
`data/connectors/calendar/skipped-calendars.log` (calendar id + timestamp +
error) and move on to the next calendar — never abort the whole sweep
because one calendar failed.

**Recurring events — VERIFY-LIVE:** `list_events` is expected to expand
recurring series into concrete in-window instances (each with its own `id`
and `start`/`end`) rather than returning the series master once, but this
has not yet been confirmed against a real recurring event on a live sweep.
The 2026-08-29 live sweep had no recurring event in-window, so this remains
open — confirm on the first live run that does surface a recurring series
and record the finding here (replacing this paragraph) before relying on
it: if instances are NOT expanded, this skill needs an explicit instance-
expansion step added before §4; if they ARE expanded, this note can be
deleted. Do not guess in code — the live run is the check.

## 4. Per-event fields

Every field below is read out of the saved page file via jq, indexed per
event as `.events[<i>]` (`<i>` the event's index within that page's array) —
the shapes here document the fields for reference, they are not copied into
model context. Each event object observed live (2026-08-29, via
`list_events`):

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

- `organizer`/`creator` are objects with at least `email`; `displayName` and
  `self: true` were also observed live on both — treat `displayName` as
  optional on either.
- The organizer is also flagged inside `attendees` via `"organizer": true`
  on that attendee entry; the user's own entry carries `"self": true`.
  Neither `self` nor `organizer` flags are used to filter hints — see §6.
- `attendees[].displayName` was observed live (not present on every
  attendee); hints fall back to bare email when no name is available.
- Other fields seen live but requiring no handling change (the body is the
  whole resource as-is): `attachments[]`, `conferenceUrl`,
  `overrideReminders`, `availability`, `transparency`, `visibility`,
  `guestPermissions`, `eventType: "FROM_GMAIL"`.
- `start`/`end` normally carry `{dateTime, timeZone}` with a UTC-offset ISO
  8601 timestamp. **Live-verified 2026-08-29:** all-day events use
  `{date: "..."}` instead of `dateTime`, and through this connector the
  `date` field arrives **already carrying the `T00:00:00Z` suffix**
  (`"date": "2026-08-03T00:00:00Z"`), not the bare `YYYY-MM-DD` form the
  general Google Calendar API convention would suggest. Handle both forms
  per §5 below — the bare form remains possible per that convention even
  though only the suffixed form was observed live.

## 5. occurred_at

Read via jq from the saved page file, e.g.
`jq -r '.events[<i>].start.dateTime // .events[<i>].start.date' <saved-page-file>`.
Event start normalized to UTC ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ`):

- Timed event (`start.dateTime` with a UTC offset) — convert to UTC.
- All-day event (`start.date`, per §4) — if `start.date` already contains a
  `T` (the live-observed form, e.g. `2026-08-03T00:00:00Z`), use it as-is;
  otherwise (bare `YYYY-MM-DD`, per the general API convention) append
  `T00:00:00Z`.

`captured_at` is the sweep run's own current UTC time (same value reused for
every item in the run, or per-item if the run is long — either is
acceptable; consistency within a run is what matters for `id` derivation).

## 6. Hints

Extract event `<i>` from the saved page file via jq and pipe it into
`scripts/extract-hints.sh`:
`jq -c '.events[<i>]' <saved-page-file> | bash scripts/extract-hints.sh`,
which emits one `"Name <email>"`-form line per organizer, creator, and every
attendee (in that order), falling back to bare email or bare name when the
other half is missing. Duplicates across organizer/creator/attendees are
expected and left as-is (no dedup). **Never filter out the user's own
address** — a `self: true` attendee still gets a hint line; filtering the
user's own identity out of the raw capture is ingestion's job, not this
sweep's.

Pass each line as its own `--hint` to `normalize-capture.sh`.

## 7. Body + raw archive

The body is the event resource, pretty-printed as JSON — the provider
resource itself, not a summary. Before normalizing, compute the capture id
up front (`<captured_at-compact>-calendar-in-calendar-<4-hex-rand>`,
matching `normalize-capture.sh`'s default id form). Both the raw archive and
the body are produced programmatically from the saved page file, indexed per
event as `.events[<i>]` — never copied through model context:

- **Raw archive** (the unmodified per-item provider output, exactly as
  returned):

  ```sh
  jq -c '.events[<i>]' <saved-page-file> > <store-dir>/archive/raw/<capture-id>.json
  ```

- **Body** (pretty-printed for normalize-capture.sh):

  ```sh
  jq '.events[<i>]' <saved-page-file> > <body-file>
  ```

  `<body-file>` is a temp file passed to `normalize-capture.sh --file
  <body-file>` in §8, rather than piping through a stdin heredoc built from
  model context.

This preserves the provenance trail across the JSON-pretty-print
transformation applied to the body, with jq (not the model) as the actor on
both the compact archive form and the pretty-printed body form.

**Inline residual (D5):** if a given `list_events` page arrives inline
instead of landing on disk (a small enough final page), write that tool
result to a temp file in **one verbatim, uninterpreted paste** — the session
never summarizes, classifies, or excerpts it from context — then proceed
identically to the disk path for every step above and below, treating that
temp file as `<saved-page-file>` for the rest of this run. Count each such
page in the run's `inline-spilled=<n>` summary field (§9). Byte fidelity is
guaranteed on the disk path, best-effort on the inline residual.

## 8. Dedup and normalize

For each event, compute the dedup key `<event-id>:<updated-timestamp>` by
reading `id` and `updated` via jq from the saved page file (e.g.
`jq -r '.events[<i>].id + ":" + .events[<i>].updated' <saved-page-file>`).
If that exact key is already present in
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
  --file <body-file from §7>
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
already-processed, events quarantined, and `inline-spilled=<n>` — the count
of `list_events` pages that arrived inline instead of on disk and were
handled via the §7 inline-residual rule (0 when every page landed on disk).

## Fetch-to-file invariant

No event body is ever read into, or written from, model context. From the
`list_events` call in §3 through dedup, raw archive, body extraction, hints,
and normalization in §4–§8, every per-event operation reads the saved page
file (or, on the inline residual, the verbatim temp-file stand-in from §7)
programmatically via jq or `scripts/extract-hints.sh` — the model only ever
handles file paths, ids, indices, and timestamps. Backfill mode (below)
inherits this invariant identically, since its §3–§7 apply unchanged.

## Invocation

This skill is invokable as a single skill run over the full multi-calendar
window described above — no external scheduler is assumed or required by
this document. Recurring/periodic invocation (launchd or otherwise) is
chunk 19's job.

## Backfill mode (onboarding, explicit invocation only)

A separate one-shot mode for a new user's onboarding session to sweep past
events over a wider, configured window without disturbing the incremental
lane's state. Invoked explicitly only — "run calendar-sweep in backfill
mode" — never wired into the sync-lanes schedule (plan 19) as a standing
row. Everything in §1, §3, §4, §5, §6, §7, and §9 above applies unchanged
(enumeration, per-calendar failure isolation, event field handling,
`occurred_at` normalization, hints, body/raw archiving, and the end-of-run
summary); only the window (§2) and the dedup/log target (§8) differ, as
follows.

**Window:** resolve the backfill window by running
`bash packages/connectors/scripts/resolve-backfill-window.sh <data-dir>`.
On success it prints one line to stdout, tab-separated:
`window_start_iso<TAB>window_months`. On a malformed config it exits
non-zero — abort the backfill run and surface its stderr rather than
guessing a window. Use `window_start_iso` as `startTime` and **now** (the
run's own current UTC time) as `endTime` for every calendar's `list_events`
call — backfill covers **window-start → now only** (past events). It never
extends into the future; the upcoming/future side of the calendar stays the
incremental sweep's job (§2), untouched by this mode.

**Dedup and log isolation (adapted from plan 24 D5 to this checkpoint-less
lane):** before capturing an event, check its dedup key
(`<event-id>:<updated-timestamp>`, per §8) against **both**
`data/connectors/calendar/processed.log` (the incremental lane's ledger) and
`data/connectors/calendar/backfill-processed.log` (this mode's own ledger,
same key format) — skip if present in either. On a successful capture
(normalize-capture.sh exit 0), append the dedup key **only** to
`backfill-processed.log`. A backfill run **never writes to
`processed.log`** — that file remains the incremental sweep's exclusively,
so a later incremental run's rolling-window dedup state is unaffected by
anything a backfill run captured. `skipped-calendars.log` (§3) is shared
and appended to by either mode, unchanged.

**Summary (§9), adapted:** report the same fields, plus explicitly label
the run as a backfill run and state the resolved window
(`window_start_iso` → now) in the summary output.
