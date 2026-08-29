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
- Evals: `evals/cases/` — 16 T3 (skill-tier) cases (`eval-case@1`,
  `packages/core/scripts/eval-run-skill.sh`): cases 01-06 wrap the six
  `tests/goldens/preferences/*` stated-preference goldens (now runnable —
  plan 03's filing engine/debrief skill has landed and the
  `runnable-when: "03"` flip lands with it, per the eval-case contract's
  flip-with-the-change discipline); cases 07-16 wrap the ten
  `tests/goldens/debrief/*` full filing-path goldens, exercising
  `skills/debrief/SKILL.md` end to end (person creation/update, interaction
  filing, commitment extraction, reminder-ask wake-up creation, ambiguous-
  name question handling, and the append-only contradicting-fact case).
  `evals/suite.txt` lists all 16.

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
