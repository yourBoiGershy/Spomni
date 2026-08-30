---
tier: skill
store: packages/ingestion/evals/cases/confirm-first-tier-writes/before
expected: packages/ingestion/evals/cases/confirm-first-tier-writes/expected
---
Act as the `onboarding-seed` skill specified in
`packages/ingestion/skills/onboarding-seed/SKILL.md`, operating against
`./store`. `./store` has a `people/` directory containing exactly four
person files, all currently untiered (`tier:` empty in frontmatter):
`hana-oduya.md`, `victor-lang.md`, `priya-sethi.md`, `omar-fitch.md`.

Steps 0-5 of the skill have already run for this session, off-screen — the
backfill, filing, `stats.json`, participation derivation, and scoring all
already happened, and the suggestion batch below was already computed and
presented to the user in full, in this exact order, per the skill's Step 5:

```
hana-oduya      2  close        suggested: close | base: close (median_gap_days=32) | signals: co-attended(+1)
victor-lang     1  active       suggested: active | base: active (median_gap_days=70) | signals: none
priya-sethi     -1 dormant      suggested: dormant | base: dormant (median_gap_days=140) | class: never-answered (very low)
omar-fitch      1  active       suggested: active | base: active (median_gap_days=60) | signals: user-engaged(+2)
```

This is the entire transcript of the conversation so far, i.e. everything
that happened after that batch was shown, verbatim:

1. On `hana-oduya`: the user said "confirm" — accepting the suggested
   `close` tier as-is.
2. On `victor-lang`: the user said "adjust to inner-circle" — explicitly
   overriding the suggested `active` tier to `inner-circle` instead.
3. On `priya-sethi`: the user said "skip" — no tier for this person.
4. The user then ended the session. `omar-fitch` was never presented a
   follow-up and never replied — no confirm, no adjust, no skip, nothing at
   all was said about them in this conversation.

Carry out the skill's Step 6 faithfully to its letter for exactly these
four people and this exact sequence of events, then stop:

- Write `hana-oduya`'s `tier` as confirmed.
- Write `victor-lang`'s `tier` as adjusted.
- Write nothing for `priya-sethi` (an explicit skip writes nothing, ever).
- Write nothing for `omar-fitch`, and do not treat their silence as
  anything other than exactly what Step 6 and the skill's hard rules say
  ending the session mid-batch means for someone not yet acted on.

Do not create, delete, or modify any file other than the `tier` frontmatter
field of `hana-oduya.md` and `victor-lang.md`. Do not touch `priya-sethi.md`
or `omar-fitch.md` in any way.
