---
tier: skill
store: packages/ingestion/tests/goldens/preferences/03-cadence-wish/before
expected: packages/ingestion/tests/goldens/preferences/03-cadence-wish/expected
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane (the "Stated-preference
lane" section of `packages/ingestion/skills/debrief/SKILL.md`), per
`packages/ingestion/specs/stated-preference-filing.md` section (c)
(cadence wishes). The current people-store is the directory `./store`
(contains `profile.md`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:20:00Z`, no
named participant) contains this utterance:

> I want to stay quarterly with my Michigan crew — don't let those go
> dormant.

File the stated-preference delta this utterance implies into `./store`,
following the spec: this is a stated rhythm ask, not a signal opt-out or
tier statement, so append a `**[stated-by-user]**` bullet (utterance lightly
cleaned up, not paraphrased into a different claim) to `profile.md`'s
`## Cadence wishes` section, dated `(2026-08-29)`. Always append, never
rewrite or merge with an existing bullet. Do not touch any other file.
