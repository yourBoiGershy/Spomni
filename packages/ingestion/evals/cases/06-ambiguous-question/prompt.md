---
tier: skill
store: packages/ingestion/tests/goldens/preferences/06-ambiguous-question/before
expected: packages/ingestion/tests/goldens/preferences/06-ambiguous-question/expected
runnable-when: "03"
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane, per
`packages/ingestion/specs/stated-preference-filing.md` section (a) (tier
utterances). The current people-store is the directory `./store` (contains
`people/` and `profile.md`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:50:00Z`,
`participant-hints: ["Alex"]`) contains this utterance:

> Alex is close now — grabbed coffee with him this week and it was great
> catching up.

Resolve "Alex" against `./store`. If `participant-hints` resolves to more
than one person in the store and the utterance gives too little context to
pick one, do NOT write anything — per the spec's ambiguous-match rule, ask
a single clarifying question naming the candidates instead of guessing.
Do not create, edit, or touch any file under `./store` while the question
is outstanding — a declined or unanswered ambiguous tier change leaves no
trace in the store.
