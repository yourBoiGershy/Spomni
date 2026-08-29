---
schema_version: 1.2.0
id: 2026-08-19-marisol-vance
due: 2026-08-19
people: ["[[marisol-vance]]"]
why: "scheduling intent: \"we should grab coffee soon\" — proposed a slot for that week"
status: dismissed
origin: signal
source-signal: 20260810T090000Z-scheduling-intent-marisol-vance
fired-on: 2026-08-19
dismiss-reason: not-now
acted-on:
snooze-count: 0
signal-type: scheduling-intent
kind: event-proposal
proposed-event:
  title: Coffee with Marisol
  start: 2026-08-21T15:00:00-07:00
  end: 2026-08-21T16:00:00-07:00
  attendees: ["[[marisol-vance]]"]
  location:
confirmed-on:
created-event-id:
---

## Context

Marisol's 2026-08-10 coffee mention (filed in
`interactions/2026-08-10-marisol-vance.md`) promoted to a proposal for Fri
2026-08-21, 3:00–4:00pm. The user dismissed it on 2026-08-19 with reason
`not-now`. Per the no-guilt / declined-proposals-are-dropped-silently rule,
this dismissed wake-up is the only record of that decline — see the
`clear-intent` and `declined-proposal` sibling fixtures' READMEs for the
same convention on the tier-drift specs.
