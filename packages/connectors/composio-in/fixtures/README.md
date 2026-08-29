# Fixtures: composio-in

All payloads below are **synthetic** — hand-written to model the
capture-event 1.1.0 **body** shape sweeps hand to
`normalize-capture.sh` (transport already unwrapped, per the standard's
"Body + transport rule" in
`docs/plans/2026-08-29-11-composio-import-standard.md`), not the raw
`composio execute <TOOL_SLUG>` wrapper. Names, emails, and post content are
invented for this repo only.

- `email-voice-note.json` — `composio-in/gmail` lane, `type: voice-note`, a
  `[ra]`-tagged self-email carrying a dictated debrief. `occurred_at` is the
  message's `Date` header (2026-08-29T13:05:00Z, omitted from the fixture body
  itself — it lives in the capture event's frontmatter, not the body). Body
  is the gmail-lane convention: `Subject:` line, blank line, rendered message
  text.
- `email-linkedin-notification.json` — `composio-in/gmail` lane,
  `type: linkedin-notification` (a LinkedIn "changed jobs" notification
  landing in Gmail). `occurred_at` is the message's `Date` header
  (2026-08-28T09:12:00Z). Same `Subject:` + blank line + rendered text body
  convention as the voice-note fixture.
- `calendar-event.json` — `composio-in/googlecalendar` lane,
  `type: calendar-event`, one event with 2 attendees (self + one other).
  `occurred_at` is the event start (2026-09-05T16:00:00-07:00).
  `participant-hints` come from the organizer/creator/attendees. Body is the
  provider event resource itself, pretty-printed JSON — no Composio CLI
  wrapper (`successful`/`data`/`error`/`logId`).
- `linkedin-post.json` — `composio-in/linkedin` lane, `type: post` (a known
  post refreshed via `LINKEDIN_GET_POST_CONTENT`). `occurred_at` is the
  post's publish time (2026-08-20T15:30:00Z, `createdAt` in the payload).
  `participant-hints` is empty — this is the user's own post.
  Body is the provider post resource itself, pretty-printed JSON — no
  Composio CLI wrapper.
- `malformed-junk.txt` — truncated/garbage input. Exercises quarantine
  behavior in the normalizer, never contract-conformant.

None of the JSON/text fixtures above carry the Composio CLI transport
wrapper (`{"successful": ..., "data": ..., "error": ..., "logId": ...}`) —
per the standard, that wrapper is stripped by the sweep before the body is
formed and the untouched wrapper is archived separately to
`archive/raw/<capture-id>.json`; it never enters `inbox/`.
