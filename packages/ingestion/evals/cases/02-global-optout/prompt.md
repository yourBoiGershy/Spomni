---
tier: skill
store: packages/ingestion/tests/goldens/preferences/02-global-optout/before
expected: packages/ingestion/tests/goldens/preferences/02-global-optout/expected
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane (the "Stated-preference
lane" section of `packages/ingestion/skills/debrief/SKILL.md`), per
`packages/ingestion/specs/stated-preference-filing.md` section (b) (signal
opt-outs). The current people-store is the directory `./store` (contains
`profile.md`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:10:00Z`, no
named participant) contains this utterance:

> Hey, can you stop nudging me about company news? I don't need those
> alerts.

File the stated-preference delta this utterance implies into `./store`,
following the spec: this is a global (not person-scoped) opt-out of the
`company-news` signal type, so append a `**[stated-by-user]**` bullet to
`profile.md`'s `## Signal opt-outs` section in the form
`<signal-type> — all`, dated `(2026-08-29)`. Never rewrite the section,
only append. Do not touch any other file.
