---
schema_version: 1.2.0
id: cal-ghost
source: calendar-in/calendar
captured_at: 2026-09-13T09:00:00Z
occurred_at: 2026-09-19T15:00:00Z
type: calendar-event
participant-hints:
  - "Ghost Person <ghost@example.test>"
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-ghost-001",
  "summary": "Quick sync",
  "start": { "dateTime": "2026-09-19T15:00:00Z" },
  "attendees": [
    { "email": "ghost@example.test", "displayName": "Ghost Person" },
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
