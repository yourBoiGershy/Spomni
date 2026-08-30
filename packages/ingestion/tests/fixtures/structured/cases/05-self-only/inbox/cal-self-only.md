---
schema_version: 1.2.0
id: cal-self-only
source: calendar-in/calendar
captured_at: 2026-09-06T09:00:00Z
occurred_at: 2026-09-13T08:00:00Z
type: calendar-event
participant-hints:
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-self-only-001",
  "summary": "Gym",
  "start": { "dateTime": "2026-09-13T08:00:00Z" },
  "attendees": [
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
