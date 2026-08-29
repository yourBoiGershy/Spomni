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

Section (b) is binding here, quoted verbatim:

> Trigger: a debrief/voice-note contains an explicit ask to stop a signal
> type — global ("stop birthday reminders", "don't nudge me about job
> changes") or person-scoped ("stop birthday reminders for Dana").
>
> Filing rule:
>
> 1. Map the utterance to a signal-type from plan 05's detector set (this
>    spec does not define that set; it consumes whatever plan 05 ships). If
>    the utterance names a signal type the detector set does not recognize,
>    ask a clarifying question rather than inventing a new signal-type
>    string — an opt-out bullet's `<signal-type>` token must match the
>    detector vocabulary exactly, or `packages/attention`'s signal-scan
>    cannot match it at suppression time.
> 2. **Global opt-out** ("stop birthday reminders", no person named):
>    append
>    ```
>    - **[stated-by-user]** birthday — all
>    ```
>    to `profile.md`'s `## Signal opt-outs` section.
> [...]
> 4. **Append, never rewrite the section.** If an equivalent opt-out bullet
>    already exists (same signal-type, same scope — `all` or the same
>    `[[slug]]`), this is a no-op, not a duplicate append — check the
>    section's existing bullets before appending.
> 5. An opt-out is never encoded any other way (never a
>    `ranking-weights.json` entry, never a tier change, never a `person.md`
>    edit) — per the contract, opt-outs suppress at the detector, before
>    ranking.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:10:00Z`, no
named participant) contains this utterance:

> Hey, can you stop nudging me about company news? I don't need those
> alerts.

This maps to the `company-news` signal type in plan 05's detector set, and
names no person, so per rule 2 above this is a **global** opt-out. File the
stated-preference delta this utterance implies into `./store`:

- Append exactly one `**[stated-by-user]**` bullet to `profile.md`'s
  `## Signal opt-outs` section, in the form `<signal-type> — all`, dated
  `(2026-08-29)` (the capture event's date) — i.e.
  `- **[stated-by-user]** company-news — all (2026-08-29)`.
- Do not touch `## Priorities`, `## Cadence wishes`, or `## Style notes`.
- Do not create, delete, or rewrite any other file in `./store`.
- Never rewrite the `## Signal opt-outs` section, only append — and do not
  rewrite the frontmatter or reorder any existing section.
