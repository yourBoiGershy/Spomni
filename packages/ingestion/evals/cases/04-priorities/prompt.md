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
(priorities). The current people-store is the directory `./store` (contains
`profile.md`) — treat it as the live store for this pass.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:30:00Z`, no
named participant) contains this utterance:

> This year I'm prioritizing fintech contacts — that's where my energy
> should go.

This is a freeform stated priority, not a signal opt-out, tier statement, or
cadence wish, so it files under section (c) of the spec. Section (c) is
binding here, quoted verbatim:

> Trigger: a debrief/voice-note contains a freeform stated priority ("family
> first this quarter") or a stated rhythm ask ("quarterly with the Michigan
> crowd") that does not fit the deterministic opt-out grammar in (b).
>
> Filing rule: append one bullet to the matching section —
> ```
> - **[stated-by-user]** <utterance, lightly cleaned up, not paraphrased into
>   a different claim> (<capture date, YYYY-MM-DD>)
> ```
> to `## Priorities` for priority statements, `## Cadence wishes` for rhythm
> statements. Always append; never rewrite or merge with an existing bullet,
> even if it appears to supersede one — profile.md is an append/update log of
> specific bullets, not a synthesized summary, so the record of what the user
> said and when stays intact.

"Lightly cleaned up, not paraphrased into a different claim" means: trim
filler and normalize casing/punctuation for a bullet, but keep the user's
actual words and their meaning intact — do not compress it into a shorter
restatement, do not drop the content (fintech contacts, this year's
prioritization), and do not invent phrasing the utterance didn't use.

Carry out this filing rule for exactly this one utterance, then stop:

- Append exactly one `**[stated-by-user]**` bullet to `profile.md`'s
  `## Priorities` section, dated `(2026-08-29)` (the capture event's date),
  per the grammar quoted above.
- Do not touch `## Cadence wishes`, `## Signal opt-outs`, or `## Style
  notes`.
- Do not create, delete, or rewrite any other file in `./store`.
- Do not rewrite the frontmatter or reorder any existing section.
