# package: ingestion

version: 0.1.0

## Purpose

Data malleability: everything that turns raw, normalized input into structured
knowledge. The filing engine (debriefs → person/interaction files), attendee↔person
matching against calendar artifacts, commitment extraction, link maintenance, and
provenance labeling. Ingestion is the sole writer of the people-store.

## Provides

- The populated store: `people/`, `interactions/`, `index.json` (single writer at
  runtime)
- Skills: `skills/debrief/` (filing engine), `skills/calendar-reconcile/`
  (attendee↔person matching, event links, un-debriefed + upcoming-briefworthy
  artifacts)
- Conventions: `needs-confirmation` and `needs-follow-up` markers, met-at /
  will-meet-at / same-event-as links

## Consumes

- `person@^1`, `interaction@^1`, `capture-event@^1`, `wakeup@^1` (core; wake-up
  creation only via core's `wakeup-add.sh`)
- Typed capture events from `connectors/gmail-in`, event artifacts from
  `connectors/calendar-in`

## Owned paths

`packages/ingestion/**`; at runtime: `people/`, `interactions/`, `index.json` in the
private data dir.

## Built by

Plans 03 (filing engine) and 04 (matching half).
