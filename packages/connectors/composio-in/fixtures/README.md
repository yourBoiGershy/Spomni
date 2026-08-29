# Fixtures: composio-in

All payloads below are **synthetic** — hand-written to match the shape of
`composio execute <TOOL_SLUG>` output, not captured from any real account.
Names, emails, and post content are invented for this repo only.

- `email-voice-note.json` — GMAIL_FETCH_EMAILS-style result; a `[ra]`-tagged
  self-email carrying a dictated debrief body. Exercises `type: voice-note`.
- `email-linkedin-notification.json` — a LinkedIn "changed jobs" notification
  landing in Gmail. Exercises `type: linkedin-notification`.
- `calendar-event.json` — GOOGLECALENDAR_EVENTS_LIST-style event with 2
  attendees (self + one other). Exercises `type: event-confirmation` and
  `participant-hints` from attendees.
- `linkedin-post.json` — own-post payload with share statistics, official
  LinkedIn member API surface only. Exercises `type: other`.
- `malformed-junk.txt` — truncated/garbage input. Exercises quarantine
  behavior in the normalizer, never contract-conformant.
