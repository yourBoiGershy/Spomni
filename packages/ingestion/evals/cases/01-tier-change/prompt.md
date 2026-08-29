---
tier: skill
store: packages/ingestion/tests/goldens/preferences/01-tier-change/before
expected: packages/ingestion/tests/goldens/preferences/01-tier-change/expected
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane (the "Stated-preference
lane" section of `packages/ingestion/skills/debrief/SKILL.md`), per
`packages/ingestion/specs/stated-preference-filing.md` section (a) (tier
utterances). The current people-store is the directory `./store` (contains
`people/`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:00:00Z`,
`participant-hints: ["Dana Whitfield"]`) contains this utterance:

> Quick note — Dana is inner-circle now, we talk every week.

File the stated-preference delta this utterance implies into `./store`,
following the spec: resolve the named person against the store, then
overwrite that person's `tier` frontmatter field in place (never append a
bullet, never touch any other file). If the match were ambiguous you would
ask a single clarifying question and write nothing — but resolve this case
normally since only one plausible match exists in the store.
