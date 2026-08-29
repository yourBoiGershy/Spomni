---
schema_version: 1.2.0
id: 2026-09-05-sam-oyelaran
due: 2026-09-05
people: ["[[sam-oyelaran]]"]
why: "scheduling intent: \"we should grab coffee sometime\" in last message"
status: fired
origin: signal
source-signal: 20260903T140000Z-scheduling-intent-sam-oyelaran
fired-on: 2026-09-05
dismiss-reason:
acted-on:
snooze-count: 0
signal-type: scheduling-intent
kind: event-proposal
proposed-event:
  title: Coffee with Sam
  start: 2026-09-08T10:00:00-07:00
  end: 2026-09-08T11:00:00-07:00
  attendees: ["[[sam-oyelaran]]"]
  location:
confirmed-on:
created-event-id: gcal-evt-abc123
---

## Context

Sam mentioned wanting to grab coffee in their 2026-09-03 message. This entry
has created-event-id set without a non-null confirmed-on, violating the
1.2.0 invariant (validator-checkable — the invariant fixture proving
validate-store.sh catches a created-event-id/confirmed-on mismatch).

## Draft

Hey Sam! You mentioned grabbing coffee — does Tuesday 9/8 at 10am work for
you?
