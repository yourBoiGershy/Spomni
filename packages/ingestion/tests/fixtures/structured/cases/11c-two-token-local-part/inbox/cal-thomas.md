---
schema_version: 1.2.0
id: cal-thomas
source: calendar-in/calendar
captured_at: 2026-09-13T09:00:00Z
occurred_at: 2026-09-18T15:00:00Z
type: calendar-event
participant-hints:
  - "thomas.wright@example.test"
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-thomas-001",
  "summary": "Quick sync",
  "start": { "dateTime": "2026-09-18T15:00:00Z" },
  "attendees": [
    { "email": "thomas.wright@example.test" },
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
