---
name: calendar-sweep
description: Pulls the user's Google Calendar events (all calendars, work + personal) into the store's inbox/ as capture events via the Composio CLI. Idempotent, read-only against the account, never deletes.
version: 0.1.0
triggers:
  keywords: [calendar sweep, calendar-in, googlecalendar, sync calendar]
model: inherit
---

# calendar-sweep

Read-only Google Calendar capture for `packages/connectors/composio-in`. This
skill's entire job, per `connector-interface.md`: write valid capture events
into `<store-dir>/inbox/`. It never matches attendees to people (that's
ingestion's job, plan 04), never summarizes, never decides a meeting is
"important enough" — every event in the window gets captured, per
`docs/DECISIONS.md#multiple-google-calendars` (all of the user's calendars,
work + personal).

## Preconditions

- The user has already run `composio link googlecalendar` out-of-band (an
  ACTIVE Composio session for `googlecalendar` is assumed, per
  `packages/connectors/composio-in/package.md`).
- `<store-dir>` is the target people-store root (i.e. `data/store`, per
  `docs/data-layout.md`) — passed as the first arg to
  `packages/connectors/scripts/normalize-capture.sh`.
- Ledger dir `data/connectors/googlecalendar/` exists or can be created; it is
  connector-local runtime state, never part of the shared store (per
  `docs/data-layout.md#connector-runtime-state`).

## Step 1 — enumerate calendars

Verified live against this Composio account (2026-08-29): the list-calendars
tool slug is **`GOOGLECALENDAR_LIST_CALENDARS`** (not the more guessable
`..._CALENDAR_LIST_LIST`, which does not exist in this account's toolkit —
confirmed via `composio tools info GOOGLECALENDAR_CALENDAR_LIST_GET`, whose
own description points at `GOOGLECALENDAR_CALENDAR_LIST_LIST`, and via
`composio search "list calendars" --toolkits googlecalendar`, whose
`recommended_plan_steps` name `GOOGLECALENDAR_LIST_CALENDARS` as the real
slug). Always re-verify with `composio tools info GOOGLECALENDAR_LIST_CALENDARS`
before relying on this — Composio toolkit versions and slugs can drift.

```sh
composio execute GOOGLECALENDAR_LIST_CALENDARS -d '{ "max_results": 250 }'
```

- Params: `page_token` (loop until `nextPageToken` is absent — do not stop at
  page one), `max_results` (max 250), `show_hidden`, `show_deleted`,
  `min_access_role` (leave unset to include read-only calendars too — this
  sweep never writes to Calendar, so `freeBusyReader`-only calendars are
  still fine to skip since they carry no event detail).
- Response shape: calendar entries live under `data.calendars[]`, **not**
  `data.items[]` (a documented pitfall for this tool — verify the actual
  response once against your account before hardening any parsing). Extract
  each calendar's `id` (the value to pass as `calendarId` in step 2) and
  `summary` (for logging only).
- Loop `page_token` until no `nextPageToken` comes back, accumulating every
  calendar `id` — this is "all calendars", not just `primary`.

## Step 2 — per calendar, pull events in the window

Default window: **past 30 days / upcoming 60 days** from "now". Anchor "now"
with `GOOGLECALENDAR_GET_CURRENT_DATE_TIME` (or the shell's own UTC clock) —
don't hardcode a date. Compute:

```
time_min = now - 30d   (RFC3339, e.g. 2026-07-30T00:00:00Z)
time_max = now + 60d   (RFC3339, e.g. 2026-10-28T00:00:00Z)
```

Verified tool slug: **`GOOGLECALENDAR_EVENTS_LIST`**. For each calendar `id`
from step 1:

```sh
composio execute GOOGLECALENDAR_EVENTS_LIST -d '{
  "calendarId": "<calendar-id-from-step-1>",
  "timeMin": "<window-start-RFC3339>",
  "timeMax": "<window-end-RFC3339>",
  "singleEvents": true,
  "orderBy": "startTime",
  "maxResults": 250
}'
```

- **`singleEvents: true` is required** — it expands recurring events into
  their concrete instances so each occurrence in the window gets its own
  capture event, instead of one opaque "series master" record. `orderBy:
  "startTime"` requires `singleEvents: true` (the tool enforces this itself).
- **Pagination:** the response carries `nextPageToken` (verified shape in
  this package's fixture, `fixtures/calendar-event.json`, under
  `data.eventsItems[]` + `data.nextPageToken`) — loop with `pageToken` set to
  the previous response's `nextPageToken` until it's absent/null. Do not
  stop at the first page; a busy calendar in a 90-day window can exceed 250
  events.
- **Timezone care:** per the tool's own warning, `timeMin`/`timeMax` ending
  in `Z` are interpreted as UTC regardless of the calendar's own timezone —
  fine for this sweep since the window is generous (30/60 days) and a few
  hours of UTC/local slop at the edges is an acceptable miss, not a
  correctness bug.
- **Alternative (documented, not the default path):**
  `GOOGLECALENDAR_EVENTS_LIST_ALL_CALENDARS` exists and can fetch a unified
  cross-calendar event list in one call (params: `time_min`/`time_max`
  required, optional `calendar_ids` — omit it to cover every calendar
  automatically, `single_events` defaults `true`, paginate via
  `max_results_per_calendar`/response paging same as above). It's a
  reasonable simplification if step 1's enumeration ever becomes a
  bottleneck, but its per-calendar-grouped response shape wasn't
  live-verified for this skill (no `execute` was run against it per this
  unit's read-only-verification constraint) — confirm the exact response
  shape with a dry run before switching the default path over to it.

## Step 3 — inline vs. file-backed results

Per `package.md`'s CLI call convention: large results are **not** returned
inline. Handle both shapes from every `composio execute` call in steps 1–2:

- Inline: `{ "successful": true, "data": { ... }, "error": null }` — read
  `data` directly.
- File-backed: `{ "storedInFile": true, "outputFilePath": "/tmp/..." }` —
  read and parse that file's JSON; it is the same shape `data` would have
  held inline. Delete or ignore the temp file afterward (it's Composio's
  scratch space, not this connector's state).

## Step 4 — dedup ledger

Ledger file: `data/connectors/googlecalendar/processed.log`, one line per
already-captured event:

```
<event-id>:<updated-timestamp>
```

- `<event-id>` is the event's own `id` field from the Calendar API response
  (stable across updates); `<updated-timestamp>` is that event's `updated`
  field (an ISO 8601 timestamp Google bumps on every edit).
- Before capturing an event, check whether `<event-id>:<updated-timestamp>`
  already appears in the ledger (`grep -qxF` is enough — no need for a
  fancier index at this volume):
  - **Present** → skip; nothing changed since the last sweep.
  - **Absent but `<event-id>:` prefix exists with a different
    `<updated-timestamp>`** → the event was edited since last capture;
    proceed to capture it again (a new capture event, not a rewrite of the
    old one — `inbox/` is append-only, per `capture-event.md`) and append the
    new `<event-id>:<updated-timestamp>` line.
  - **Absent entirely** → new event; capture it, append the line.
- Append-only ledger, never rewritten or compacted by this skill. Create
  `data/connectors/googlecalendar/` if it doesn't exist yet
  (`mkdir -p`).

## Step 5 — one capture event per in-window instance

For each event surviving the dedup check, call the shared normalizer:

```sh
echo '<raw event JSON, byte-for-byte from the API response>' | \
  packages/connectors/scripts/normalize-capture.sh <store-dir> \
    --source googlecalendar \
    --type other \
    --captured-at <event start, ISO 8601 UTC> \
    --hint "<attendee 1 email or displayName>" \
    --hint "<attendee 2 email or displayName>" \
    ...
```

- `--captured-at` uses the event's own `start.dateTime` (or `start.date` for
  all-day events, normalized to `T00:00:00Z`) converted to UTC — not the
  sweep's wall-clock run time. This is when the underlying thing happened,
  which is what `captured_at` in `capture-event.md` calls for on a calendar
  source.
- `--type other`, per this skill's brief. `fixtures/README.md` documents
  `fixtures/calendar-event.json` as exercising `type: other` too — the two
  agree.
- `--hint` per attendee: pass every attendee's `email` (fall back to
  `displayName` if `email` is absent) **except the user's own entry**
  (identify it via that attendee's `self: true` flag in the response, per
  the fixture). Matching these hints to `[[slug]]` people-links is
  explicitly ingestion's job (plan 04), not this skill's.
- Body: the raw event JSON object for that instance, verbatim, exactly as
  returned by the API (pretty-printed or compact, doesn't matter — no
  trimming, no field removal, no re-serialization changes). This is the
  capture event's envelope-only guarantee from `capture-event.md`.
- The normalizer derives its own `id` (`<captured_at-compact>-<source>-<rand>`)
  unless you pass `--id`; letting it default is fine here since the ledger
  (step 4), not the capture-event `id`, is this skill's dedup key.
- On success (`exit 0`), the normalizer prints the written `inbox/<id>.md`
  path to stdout — append the ledger line (`<event-id>:<updated-timestamp>`)
  only after that success, so a mid-batch crash re-attempts the event next
  run instead of silently losing it.

## Step 6 — recurring events

Because step 2 always sets `singleEvents: true`, the API already hands back
concrete in-window **instances**, not series masters — there is nothing
further to expand. Each instance has its own `id`/`updated` (distinct from
the recurring series' master event id), so the dedup ledger in step 4 treats
each occurrence independently: an edit to one instance re-captures only that
instance, not the whole series. Never call this skill with `singleEvents:
false` — that would hand back one record per series (the master) plus
possibly detached exceptions, which is a different, coarser unit than what
this skill's dedup and capture logic is built around.

## Failure posture

- **Per-event isolation:** if `normalize-capture.sh` quarantines an event
  (malformed body, duplicate `id` collision, etc.), it lands in
  `<store-dir>/inbox/quarantine/` with a reason file — the sweep logs it and
  moves on to the next event. One bad event never aborts the batch.
- **Per-calendar isolation:** if a `GOOGLECALENDAR_EVENTS_LIST` call for one
  calendar fails (e.g. that calendar was unshared mid-sweep), log the
  calendar id and error, skip to the next calendar. Don't abort the whole
  sweep over one calendar.
- **Never deletes:** this skill only ever appends to `inbox/` (via the
  normalizer) and appends to its own ledger. It does not remove ledger
  lines, does not touch `inbox/quarantine/`, and never calls any
  Calendar-mutating tool (`GOOGLECALENDAR_DELETE_EVENT`,
  `GOOGLECALENDAR_CLEAR_CALENDAR`, etc.) — this lane is read-only against
  the account end to end, per `docs/DECISIONS.md#composio-hub` and
  `docs/DECISIONS.md#draft-never-send`.
- **Partial-batch reporting:** at the end of a run, summarize counts (events
  seen, captured, skipped-unchanged, quarantined, calendars failed) so a
  human can spot a systemic problem (e.g. every event from one calendar
  quarantining) without needing to read the ledger by hand.
