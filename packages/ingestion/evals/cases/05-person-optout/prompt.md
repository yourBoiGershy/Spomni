---
tier: skill
store: packages/ingestion/tests/goldens/preferences/05-person-optout/before
expected: packages/ingestion/tests/goldens/preferences/05-person-optout/expected
runnable-when: "03"
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane, per
`packages/ingestion/specs/stated-preference-filing.md` section (b) (signal
opt-outs). The current people-store is the directory `./store` (contains
`profile.md` and `people/`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:40:00Z`,
`participant-hints: ["Ben Whitmore"]`) contains this utterance:

> No birthday reminders for Ben, please — he doesn't care about that stuff.

File the stated-preference delta this utterance implies into `./store`,
following the spec: this is a person-scoped opt-out of the `birthday`
signal type, so resolve the named person against the store and append a
`**[stated-by-user]**` bullet to `profile.md`'s `## Signal opt-outs`
section in the form `birthday — [[<resolved-slug>]]`, dated `(2026-08-29)`.
Never rewrite the section, only append. The resolved person's own
`people/*.md` file must not be touched — an opt-out is never encoded as a
`person.md` edit.
