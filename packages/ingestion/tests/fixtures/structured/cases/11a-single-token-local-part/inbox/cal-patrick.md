---
schema_version: 1.2.0
id: cal-patrick
source: calendar-in/calendar
captured_at: 2026-09-13T09:00:00Z
occurred_at: 2026-09-16T15:00:00Z
type: calendar-event
participant-hints:
  - "patrick@example.test"
  - "Me Myself <me@example.test>"
---
{
  "id": "evt-patrick-001",
  "summary": "Quick sync",
  "start": { "dateTime": "2026-09-16T15:00:00Z" },
  "attendees": [
    { "email": "patrick@example.test" },
    { "email": "me@example.test", "displayName": "Me Myself", "self": true }
  ]
}
