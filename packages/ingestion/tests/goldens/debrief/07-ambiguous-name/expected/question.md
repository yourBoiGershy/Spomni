# Clarifying question

**Trigger utterance:** "Grabbed coffee with Sarah today, she said the new job
is going really well and she's already leading a small team."

**Reason:** `participant-hints: ["Sarah"]` resolves to more than one person
in the store — `[[sarah-chen]]` (Sarah Chen) and `[[sarah-park]]` (Sarah
Park) — and the stated update (a new role, already leading a team) is a
high-value fact about which Sarah is progressing, so the one-question rule
(per `docs/plans/2026-08-29-03-filing-engine.md`'s capture-optional /
lossy-tolerant doctrine) applies: ask once rather than guess or file against
both.

**Candidates:**
- `[[sarah-chen]]` — Sarah Chen, Senior Consultant at Bright Path Consulting
- `[[sarah-park]]` — Sarah Park, Engineering Manager at Vantage Robotics

**Question posed to the user:**
"Which Sarah do you mean — Sarah Chen or Sarah Park?"

**Store writes performed:** none. No `people/*.md`, `interactions/*.md`, or
`wakeups/*.md` file is created, edited, or touched while the question is
outstanding; the raw capture event remains archived in `inbox/` for a
follow-up filing pass once the user answers. If the user never answers or
declines, the fact is dropped silently — it is never re-asked and never
guessed (no-guilt principle).
