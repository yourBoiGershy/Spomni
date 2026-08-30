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
  artifacts), `skills/onboarding-seed/` (session-driven, one-shot fresh-install
  pass: sequences the three lanes' backfill modes, normal filing,
  `build-stats.sh`, and the two seed-time scripts below into one batched,
  human-confirmed tier-suggestion presentation, per plan 24)
- Scripts: `scripts/derive-participation.sh` (read-only; derives per-person
  `user_engaged`/`group_linked` participation flags from preserved raw
  capture events, ephemeral input to onboarding tier suggestions — never
  written to the store), `scripts/suggest-tiers.sh` (read-only; applies the
  deterministic D3 scoring model to `stats.json` + the participation flags,
  emitting the ordered, capped suggestion batch — both plan 24),
  `scripts/triage-inbox.sh` (read-only over `<store-dir>`; sole writer of
  the `data/ingestion/triage-held.log` ledger — deterministic, no-model
  pre-judgment hold pass over `inbox/`, applying `specs/import-triage.md`'s
  five rule classes, plan 26)
- Specs: `specs/stated-preference-filing.md` — how tier utterances, signal opt-outs,
  priorities, and cadence wishes file into `person.md`/`profile.md`, including the
  tier-change confirmation path (amends plan 03's filing-engine brief; plan 03 is
  unbuilt); `specs/onboarding-tiering-seed.md` — the cold-start tier-suggestion
  sequence, scoring model, and no-guilt presentation rules `skills/onboarding-seed/`
  runs (plan 11 unit 13, amended by plan 24 for the 6-month configurable window +
  participation-signal scoring); `specs/import-triage.md` — the five
  deterministic, precision-first junk-hold rule classes and the D3
  held-by-rule ledger convention (plan 26)
- Ledger: `data/ingestion/triage-held.log` (sole writer:
  `scripts/triage-inbox.sh`) — append-only, tab-separated
  `<capture-id>\t<rule-name>\t<held-at ISO 8601 Z>`, one line per held
  event; read by `skills/debrief/` batch mode (excluded alongside
  `debrief-filed.log`) and by humans directly, per `specs/import-triage.md`
  D3 (plan 26)
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

- `person@^1`, `interaction@^1`, `capture-event@^1`, `wakeup@^1`, `profile@^1`,
  `onboarding-backfill@^1.0`, `import-pipeline@^1` (core; wake-up creation only via core's
  `wakeup-add.sh`; `profile@^1` and `person@^1` tier writes per
  `specs/stated-preference-filing.md`; `onboarding-backfill@^1.0` read by
  `skills/onboarding-seed/` and `scripts/derive-participation.sh` for the
  configured window and `self` identities, per plan 24; `import-pipeline@^1`
  is the five-stage fetch→normalize→triage→judgment→file contract that
  `scripts/triage-inbox.sh` and `skills/debrief/`'s triage-held exclusion
  implement the triage/judgment stages of, per plan 26)
- Typed capture events from `connectors/gmail-in`, event artifacts from
  `connectors/calendar-in`
- Tier-change proposal wake-ups from `packages/attention` (read-only — the
  confirmation reply is what ingestion files; `attention` never writes `person.md` or
  `profile.md` directly, per `docs/DECISIONS.md#preference-provenance`)

## Owned paths

`packages/ingestion/**`; at runtime: `people/`, `interactions/`, `index.json` in the
private data dir.

## Built by

Plans 03 (filing engine) and 04 (matching half). `skills/onboarding-seed/`,
`scripts/derive-participation.sh`, `scripts/suggest-tiers.sh`, and the
`onboarding-tiering-seed.md` spec amendment by plan 24
(docs/plans/2026-08-29-24-onboarding-backfill-priority-seeding.md).
`scripts/triage-inbox.sh`, `specs/import-triage.md`, the
`data/ingestion/triage-held.log` ledger, and `skills/debrief/`'s
triage-held batch-mode exclusion by plan 26 (standard import pipeline).
