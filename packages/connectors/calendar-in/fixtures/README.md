# calendar-in fixtures

Synthetic `mcp__claude_ai_Google_Calendar__*` tool-output shapes for offline
testing of `scripts/extract-hints.sh` and the capture test suite. All PII is
synthetic — `example.com`/`example.org` domains and invented names only, per
`docs/DECISIONS.md#pii-egress-allowlist`. No real calendar data appears
here.

## Live-verified vs. assumed (2026-08-29)

- `calendar-event.json` — **live-verified** shape. Field names (`id`,
  `summary`, `status`, `eventType`, `location`, `htmlLink`, `conferenceUrl`,
  `created`, `updated`, `creator`, `organizer`, `start`/`end` as
  `{dateTime, timeZone}`, `attendees[]` with `email`/`organizer`/`self`/
  `responseStatus`) were observed directly via `list_events` against the
  user's real primary calendar in-session on 2026-08-29 (see
  `/private/tmp/.../scratchpad/calendar-live-shape.md`, carried into plan
  17). Values here are synthetic; the shape is not.
- `calendars-list.json` — **live-verified** envelope shape (`calendars[]`
  with `id`/`summary`/`timeZone`, `description` optional), from
  `list_calendars` in the same session.
- `calendar-event-allday.json` — **assumed, not live-verified**. No all-day
  event appeared in the sampled window, so the `start`/`end` as
  `{date: "YYYY-MM-DD"}` form (rather than `{dateTime, timeZone}`) is an
  assumption based on the general Google Calendar API convention, not a
  confirmed first-party-connector observation. Treat this fixture — and the
  all-day handling branch in `skills/calendar-sweep/SKILL.md` §4/§5 — as
  unverified until a real all-day event is captured on a live sweep.
- `displayName` on `organizer`/`creator`/`attendees` was never observed live
  (every sampled participant had only an `email`) — treat it as optional
  wherever it appears in code/docs; `extract-hints.sh` falls back to bare
  email in its absence.
