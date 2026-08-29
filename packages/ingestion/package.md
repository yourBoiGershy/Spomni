# package: ingestion

version: 0.1.0

## Purpose

Data malleability: everything that turns raw, normalized input into structured
knowledge. The filing engine (debriefs → person/interaction files), attendee↔person
matching against calendar artifacts, commitment extraction, link maintenance, and
provenance labeling. Ingestion is the sole writer of the people-store.

## Provides

- The populated store: `people/`, `interactions/`, `index.json` (single writer at
  runtime); `profile.md` (single writer at runtime — stated preferences and, after
  user confirmation, style notes)
- Skills: `skills/debrief/` (filing engine), `skills/calendar-reconcile/`
  (attendee↔person matching, event links, un-debriefed + upcoming-briefworthy
  artifacts)
- Specs: `specs/stated-preference-filing.md` — how tier utterances, signal opt-outs,
  priorities, and cadence wishes file into `person.md`/`profile.md`, including the
  tier-change confirmation path (amends plan 03's filing-engine brief; plan 03 is
  unbuilt)
- Conventions: `needs-confirmation` and `needs-follow-up` markers, met-at /
  will-meet-at / same-event-as links

## Consumes

- `person@^1`, `interaction@^1`, `capture-event@^1`, `wakeup@^1`, `profile@^1` (core;
  wake-up creation only via core's `wakeup-add.sh`; `profile@^1` and `person@^1` tier
  writes per `specs/stated-preference-filing.md`)
- Typed capture events from `connectors/gmail-in`, event artifacts from
  `connectors/calendar-in`
- Tier-change proposal wake-ups from `packages/attention` (read-only — the
  confirmation reply is what ingestion files; `attention` never writes `person.md` or
  `profile.md` directly, per `docs/DECISIONS.md#preference-provenance`)

## Owned paths

`packages/ingestion/**`; at runtime: `people/`, `interactions/`, `index.json` in the
private data dir.

## Built by

Plans 03 (filing engine) and 04 (matching half).
