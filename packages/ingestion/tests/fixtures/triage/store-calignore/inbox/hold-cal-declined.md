---
schema_version: 1.2.0
id: hold-cal-declined
source: calendar-in/calendar
captured_at: 2026-08-03T09:00:00Z
type: calendar-event
participant-hints:
  - "Jordan Ellery <jordan.ellery@example.net>"
---
{
  "summary": "Quarterly planning",
  "start": { "dateTime": "2026-08-10T15:00:00Z" },
  "attendees": [
    { "email": "me@example.com", "self": true, "responseStatus": "declined" },
    { "email": "jordan.ellery@example.net", "displayName": "Jordan Ellery", "responseStatus": "accepted" }
  ]
}
