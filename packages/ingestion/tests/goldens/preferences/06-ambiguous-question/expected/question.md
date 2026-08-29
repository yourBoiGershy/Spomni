# Clarifying question

**Trigger utterance:** "Alex is close now — grabbed coffee with him this week and it was great catching up."

**Reason:** `participant-hints: ["Alex"]` resolves to more than one person in the
store — `[[alex-rivera]]` (Alex Rivera) and `[[alex-tanner]]` (Alex Tanner) —
and the stated tier change ("close") is a high-value fact, so the one-question
rule (per `docs/plans/2026-08-29-03-filing-engine.md`'s capture-optional /
lossy-tolerant doctrine) applies: ask once rather than guess.

**Candidates:**
- `[[alex-rivera]]` — Alex Rivera, Operations Manager at Northwind Logistics
- `[[alex-tanner]]` — Alex Tanner, Art Director at Riverside Design Co

**Question posed to the user:**
"Which Alex do you mean — Alex Rivera or Alex Tanner?"

**Store writes performed:** none. No `people/*.md` or `profile.md` file is
created, edited, or touched while the question is outstanding. If the user
answers, a follow-up filing pass applies the tier delta to the named person
(shape identical to the `01-tier-change` golden). If the user never answers
or declines, the tier change is dropped silently — it is never re-asked and
never guessed (no-guilt principle).
