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
- `calendar-event-allday.json` — **live-verified 2026-08-29**. Three all-day
  holiday events appeared in the live sweep window; `start`/`end` arrived as
  `{date: "YYYY-MM-DDT00:00:00Z"}` — the `date` field carries the
  `T00:00:00Z` suffix already, not the bare `YYYY-MM-DD` form the general
  Google Calendar API convention would suggest. The skill's occurred_at
  handling (`skills/calendar-sweep/SKILL.md` §5) still accepts the bare form
  too, since it remains possible per that convention, but this is the form
  actually observed through this connector.
- A calendar with no in-window events returns a `list_events` envelope with
  **no `events` key at all** (not an empty array) — e.g.
  `{"accessRole":"owner","summary":"School","timeZone":"America/Toronto","updated":"..."}` —
  observed live 2026-08-29. This is a valid no-results state, not an error.
- `displayName` on `organizer`/`creator`/`attendees` was observed live on
  2026-08-29 (attendees carrying `displayName`; `organizer`/`creator`
  carrying `displayName` and `self: true`) — treat it as optional wherever it
  appears in code/docs; `extract-hints.sh` falls back to bare email in its
  absence.
