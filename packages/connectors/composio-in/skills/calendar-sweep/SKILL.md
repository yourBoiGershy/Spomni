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

- Params: `page_token` (loop until `next_page_token` is absent — do not stop
  at page one), `max_results` (max 250), `show_hidden`, `show_deleted`,
  `min_access_role` (leave unset to include read-only calendars too — this
  sweep never writes to Calendar, so `freeBusyReader`-only calendars are
  still fine to skip since they carry no event detail).
- Response shape: calendar entries live under `data.calendars[]`, **not**
  `data.items[]` (a documented pitfall for this tool — verify the actual
  response once against your account before hardening any parsing). Extract
  each calendar's `id` (the value to pass as `calendarId` in step 2) and
  `summary` (for logging only).
- Loop `page_token` until no `next_page_token` comes back (live-verified
  2026-08-29, toolkit version `20260826_00`: the field is `next_page_token`,
  snake_case), accumulating every calendar `id` — this is "all calendars",
  not just `primary`.

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
- **Pagination:** events live under `data.items[]`, **not** `data.eventsItems[]`
  (live-verified 2026-08-29, toolkit version `20260826_00` — see this
  package's fixture, `fixtures/calendar-event.json`, under `data.items[]`).
  When there's a next page, the response carries `data.nextPageToken`; when
  there isn't one, the key is **absent entirely**, not present-and-null —
  loop with `pageToken` set to the previous response's `nextPageToken` until
  the key is absent. Do not stop at the first page; a busy calendar in a
  90-day window can exceed 250 events.
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

For each event surviving the dedup check, unwrap the Composio CLI wrapper first —
the event object handed to the normalizer must be the **provider event resource
itself**, never the `{"successful": ..., "data": ...}` wrapper (or the
`outputFilePath`-backed equivalent from step 3). Pretty-print it as JSON, then call
the shared normalizer:

```sh
EVENT_JSON="<the event object from data.items[], unwrapped>"
EVENT_JSON_PRETTY="$(printf '%s' "$EVENT_JSON" | jq '.')"

HINT_ARGS=""
while IFS= read -r hint; do
  HINT_ARGS="$HINT_ARGS --hint $(printf '%q' "$hint")"
done < <(printf '%s' "$EVENT_JSON" | jq -r '
  ( .organizer? | ((.displayName // "") + (if .email then " <" + .email + ">" else "" end)) ),
  ( .creator?   | ((.displayName // "") + (if .email then " <" + .email + ">" else "" end)) ),
  ( .attendees[]? | ((.displayName // "") + (if .email then " <" + .email + ">" else "" end)) )
' | sed 's/^ <//; s/^ $//' | grep -v '^$')

# Archive the untouched CLI output for this event's raw provenance trail
# (the body below is a transformation — pretty-printed — of it).
mkdir -p <store-dir>/archive/raw
printf '%s' "$EVENT_JSON" > "<store-dir>/archive/raw/${CAPTURE_ID}.json"

printf '%s\n' "$EVENT_JSON_PRETTY" | \
  eval "packages/connectors/scripts/normalize-capture.sh <store-dir> \
    --source composio-in/googlecalendar \
    --type calendar-event \
    --captured-at \"\$(date -u '+%Y-%m-%dT%H:%M:%SZ')\" \
    --occurred-at <event start, ISO 8601 UTC> \
    --id \"\$CAPTURE_ID\" \
    $HINT_ARGS"
```

- `--source composio-in/googlecalendar` per the import standard's
  `<connector>/<lane>` convention — this replaces the old bare `googlecalendar`
  value.
- `--type calendar-event`, per
  `docs/plans/2026-08-29-11-composio-import-standard.md`'s per-lane mapping —
  this replaces the old `--type other`. `fixtures/calendar-event.json` and
  `fixtures/README.md` must agree with this value (updated in the same plan's
  fixtures unit).
- `--captured-at` is the **sweep's own run time** (current UTC clock) — **not**
  the event start time. This is the fix the import standard was written for:
  today's instructions used the event start as `captured_at`, which produced
  files dated by when the meeting happens rather than when the sweep ran.
  `captured_at` means capture time, per `capture-event.md`; the `id` (and
  filename) derive from this value, so a batch of events captured in the same
  run gets ids clustered around "now", not scattered across the event window.
- `--occurred-at` uses the event's own `start.dateTime` (or `start.date` for
  all-day events, normalized to `T00:00:00Z`) converted to UTC — when the
  meeting actually happens. This is the field that used to have nowhere to
  live; it now carries what `--captured-at` wrongly carried before.
- Compute `CAPTURE_ID` yourself (rather than letting the normalizer default it)
  only if you need it before the call for the `archive/raw/` filename — e.g.
  `CAPTURE_ID="$(date -u '+%Y%m%dT%H%M%SZ')-composio-in-googlecalendar-$(head -c4
  /dev/urandom | xxd -p)"` (or any scheme matching `capture-event.md`'s
  recommended `<captured_at-compact>-<source>-<short-rand>` form) and pass it via
  `--id`; otherwise let the normalizer derive its own id and skip the
  `archive/raw/` step's exact filename correlation (not recommended — the
  provenance trail depends on the raw file's name matching the capture id).
- `--hint` per participant: pass the **organizer**, the **creator**, and every
  **attendee** — not attendees alone. Use each one's `"Name <email>"` form as
  seen in the response (fall back to email-only or name-only if one half is
  absent). Do **not** exclude the user's own entry — capture every participant
  as seen; per the import standard's noise policy, filtering by relevance is
  the filing engine's job (plan 04), not this sweep's. Matching these hints to
  `[[slug]]` people-links is likewise ingestion's job.
- `fixtures/calendar-event.json` (as of this unit) only exercises `attendees` —
  it has no `organizer`/`creator` fields yet. Confirm the real response's
  `organizer`/`creator` shape via `composio tools info
  GOOGLECALENDAR_EVENTS_LIST` or a live call before relying on the `jq` filter
  above; the Calendar API convention is `{ "organizer": { "email": ...,
  "displayName": ..., "self": true|absent }, "creator": { ... } }`, same shape
  as an attendee entry.
- Body: the provider event resource, pretty-printed as JSON (see
  `EVENT_JSON_PRETTY` above) — never the raw CLI wrapper. Because this is a
  transformation of the untouched API response (unwrapped, pretty-printed),
  archive the untouched response at
  `<store-dir>/archive/raw/<capture-id>.json` per `docs/data-layout.md`, using
  the same `CAPTURE_ID` passed to `--id` so the two files correlate.
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

## Backfill mode (one-time, cold-start only)

Not part of the recurring incremental sweep (steps 1-6) — invoked explicitly, either
by the user asking for it or by onboarding (per plan 11 unit 13, which feeds a
backfill's captured events into `stats.json` frequency priors so onboarding can
suggest contact tiers for the user to confirm — never auto-set). Still script-driven
via the Composio CLI, same as the rest of this skill (per the composio-dual-transport
decision) — no live-model tool loop.

**Purpose:** pull ~12 months of past Calendar events in one pass so cold-start tier
suggestions have enough signal, without ever touching the incremental ledger that
step 4 depends on for its next scheduled run.

**State this mode owns — a separate namespace, never the incremental files above:**

- `data/connectors/googlecalendar/backfill-checkpoint` — a single ISO 8601 UTC
  timestamp marking backfill progress (the oldest event `start` time successfully
  processed so far, since backfill walks backward from "now" toward the window
  start). Absent before the first backfill run; present and updated as an
  interrupted backfill resumes.
- `data/connectors/googlecalendar/backfill-processed.log` — dedup ledger for events
  captured by backfill, same `<event-id>:<updated-timestamp>` line shape as step 4's
  ledger.

**Backfill never writes `data/connectors/googlecalendar/processed.log`** — that file
is the incremental sweep's exclusively (single-writer, and backfill is not that
writer). Backfill only *reads* `processed.log` (read-only) to skip events the
incremental sweep already captured; it never appends to it, never rewrites it, never
deletes from it.

### Date-range window

Default: 12 months in the past, ending at "now" (or, if narrower is wanted for a
resumed run, ending at `backfill-checkpoint`). Unlike the incremental sweep's 30-day
past window, backfill only looks backward — it does not also pull upcoming events
(the incremental sweep already covers the future window and remains the sole source
for those).

```sh
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"   # or GOOGLECALENDAR_GET_CURRENT_DATE_TIME
BACKFILL_CHECKPOINT_FILE="data/connectors/googlecalendar/backfill-checkpoint"

WINDOW_START="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" -v-12m '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -d "$NOW -12 months" '+%Y-%m-%dT%H:%M:%SZ')"

if [ -f "$BACKFILL_CHECKPOINT_FILE" ]; then
  WINDOW_END="$(cat "$BACKFILL_CHECKPOINT_FILE")"   # resume: only what's older than last progress
else
  WINDOW_END="$NOW"
fi
```

For each calendar `id` (enumerated exactly as step 1 — all calendars, work +
personal):

```sh
composio execute GOOGLECALENDAR_EVENTS_LIST -d "{
  \"calendarId\": \"<calendar-id>\",
  \"timeMin\": \"$WINDOW_START\",
  \"timeMax\": \"$WINDOW_END\",
  \"singleEvents\": true,
  \"orderBy\": \"startTime\",
  \"maxResults\": 250
}"
```

- Same chunked-fetching discipline as step 2: page via `pageToken`/`nextPageToken`
  until absent, per-calendar isolation on failure (log and skip to the next
  calendar), `singleEvents: true` always (per step 6's reasoning — never fetch series
  masters).
- Fetch newest-to-oldest within the window and advance `backfill-checkpoint` to the
  oldest event `start` time successfully processed after each page/calendar — this
  makes an interrupted backfill resumable: a re-run only queries older than
  `backfill-checkpoint` instead of re-walking the whole 12 months. Once
  `WINDOW_START` is reached, the backfill is complete; leaving `backfill-checkpoint`
  in place afterward is harmless.

### Dedup

For each event surviving the per-calendar fetch:

1. Check `data/connectors/googlecalendar/processed.log` (the incremental ledger)
   read-only, same `<event-id>:<updated-timestamp>` match rule as step 4 — if
   present, skip (the incremental sweep already captured it; backfill must not
   duplicate that capture event).
2. Check `data/connectors/googlecalendar/backfill-processed.log` — if present, skip
   (this backfill run, or a prior interrupted one, already captured it).
3. Otherwise, capture via the same normalizer call as step 5 (unchanged: `--type
   other`, per-attendee `--hint`s excluding the user's own entry, raw event JSON
   verbatim as the body), then append `<event-id>:<updated-timestamp>` to
   `data/connectors/googlecalendar/backfill-processed.log` only.

Capture events land in `inbox/` (and raw payloads in `archive/raw/` where the
underlying capture pipeline already does that) through the exact same
`normalize-capture.sh` path as the incremental sweep — backfill is not a different
pipeline, only a different source-selection and checkpoint namespace in front of it.

### What backfill must never do

- Never append to, rewrite, or delete from
  `data/connectors/googlecalendar/processed.log` (read-only access only, for dedup).
- Never advance any state the incremental sweep reads besides
  `backfill-checkpoint`/`backfill-processed.log` themselves — backfill finishing does
  not imply the incremental sweep is "caught up" to any point, since backfill walks a
  historical window independently of the incremental sweep's own 30-day-past/60-day-
  future window.

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
