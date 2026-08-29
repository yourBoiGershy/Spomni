---
tier: skill
store: packages/ingestion/tests/goldens/preferences/04-priorities/before
expected: packages/ingestion/tests/goldens/preferences/04-priorities/expected
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane (the "Stated-preference
lane" section of `packages/ingestion/skills/debrief/SKILL.md`), per
`packages/ingestion/specs/stated-preference-filing.md` section (c)
(priorities). The current people-store is the directory `./store`
(contains `profile.md`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:30:00Z`, no
named participant) contains this utterance:

> This year I'm prioritizing fintech contacts — that's where my energy
> should go.

File the stated-preference delta this utterance implies into `./store`,
following the spec: this is a freeform stated priority, not a signal
opt-out, tier statement, or cadence wish, so append a `**[stated-by-user]**`
bullet (utterance lightly cleaned up, not paraphrased into a different
claim) to `profile.md`'s `## Priorities` section, dated `(2026-08-29)`.
Always append, never rewrite or merge with an existing bullet. Do not touch
any other file.
