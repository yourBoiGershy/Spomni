---
schema_version: 1.2.0
id: cal-jo
source: calendar-in/calendar
captured_at: 2026-09-13T09:00:00Z
occurred_at: 2026-09-20T15:00:00Z
type: calendar-event
participant-hints:
  - "jo@example.test"
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-jo-001",
  "summary": "Quick sync",
  "start": { "dateTime": "2026-09-20T15:00:00Z" },
  "attendees": [
    { "email": "jo@example.test" },
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
