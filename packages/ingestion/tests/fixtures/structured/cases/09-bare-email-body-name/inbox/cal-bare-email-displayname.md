---
schema_version: 1.2.0
id: cal-bare-email-displayname
source: calendar-in/calendar
captured_at: 2026-09-08T09:00:00Z
occurred_at: 2026-09-15T11:00:00Z
type: calendar-event
participant-hints:
  - "morgan.lee@example.test"
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-bare-email-001",
  "summary": "Vendor intro",
  "start": { "dateTime": "2026-09-15T11:00:00Z" },
  "attendees": [
    { "email": "morgan.lee@example.test", "displayName": "Morgan Lee" },
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
