---
tier: skill
store: packages/ingestion/tests/goldens/preferences/05-person-optout/before
expected: packages/ingestion/tests/goldens/preferences/05-person-optout/expected
max-turns: 8
model: haiku
---
Act as ingestion's stated-preference filing lane (the "Stated-preference
lane" section of `packages/ingestion/skills/debrief/SKILL.md`), per
`packages/ingestion/specs/stated-preference-filing.md` section (b) (signal
opt-outs). The current people-store is the directory `./store` (contains
`profile.md` and `people/`) — treat it as the live store for this pass.

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
> 2. **Global opt-out** ("stop birthday reminders", no person named): append
>    ```
>    - **[stated-by-user]** birthday — all
>    ```
>    to `profile.md`'s `## Signal opt-outs` section.
> 3. **Person-scoped opt-out** ("stop birthday reminders for Dana"): resolve
>    the named person the same way as (a) — ambiguous → ask, no match →
>    new-person flow first, then opt-out — and append:
>    ```
>    - **[stated-by-user]** birthday — [[dana-whitfield]]
>    ```
>    using the resolved slug.
> 4. **Append, never rewrite the section.** If an equivalent opt-out bullet
>    already exists (same signal-type, same scope — `all` or the same
>    `[[slug]]`), this is a no-op, not a duplicate append — check the
>    section's existing bullets before appending.
> 5. An opt-out is never encoded any other way (never a
>    `ranking-weights.json` entry, never a tier change, never a `person.md`
>    edit) — per the contract, opt-outs suppress at the detector, before
>    ranking.

A debrief/voice-note capture event (`captured_at: 2026-08-29T09:40:00Z`,
`participant-hints: ["Ben Whitmore"]`) contains this utterance:

> No birthday reminders for Ben, please — he doesn't care about that stuff.

This maps to the `birthday` signal type, and names a person ("Ben"), so per
rule 3 above this is a **person-scoped** opt-out. Resolve "Ben" against
`./store/people/` (there is exactly one unambiguous match, `ben-whitmore`).
File the stated-preference delta this utterance implies into `./store`:

- Append exactly one `**[stated-by-user]**` bullet to `profile.md`'s
  `## Signal opt-outs` section, in the form `<signal-type> — [[<slug>]]`,
  dated `(2026-08-29)` (the capture event's date) — i.e.
  `- **[stated-by-user]** birthday — [[ben-whitmore]] (2026-08-29)`. Write
  the bullet as plain Markdown text — do not wrap the bullet, or any part of
  it, in a code span (backticks); the bullet is prose with an inline
  `[[wiki-link]]`, not a code block.
- Do not touch `## Priorities`, `## Cadence wishes`, or `## Style notes`.
- An opt-out is never encoded as a `person.md` edit (rule 5 above) — the
  resolved person's own `./store/people/ben-whitmore.md` file must not be
  touched, created, deleted, or renamed.
- Do not create, delete, or rewrite any other file in `./store`.
- Never rewrite the `## Signal opt-outs` section, only append — and do not
  rewrite the frontmatter or reorder any existing section.
