# Spec: stated-preference filing

Status: spec (not yet implemented — amends `docs/plans/2026-08-29-03-filing-engine.md`'s
`skills/debrief/SKILL.md` brief; plan 03 is unbuilt as of this writing). This spec is
binding on whichever worker later implements or extends the debrief skill: it does not
replace plan 03's brief, it adds a preference-filing lane to it.

## Scope

How stated-preference utterances inside a debrief/voice-note capture event — tier
statements, signal opt-outs, priorities, cadence wishes — become writes to
`people/<slug>.md` (`packages/core/contracts/person.md`) and `profile.md`
(`packages/core/contracts/profile.md`). This is a lane alongside plan 03's fact/
interaction/commitment filing, triggered by the same debrief pass, not a separate skill
or a separate capture-event type.

Single-writer rule (binding, restated from `packages/ingestion/package.md` and both
contracts): **ingestion is the sole writer of `profile.md` and `people/*.md`.** No other
package — not `attention`, not `query` — ever writes either. `attention` may only
*propose* (see confirmation path below); the write, when it happens, is always an
ingestion write.

Provenance rule (binding, `docs/DECISIONS.md#preference-provenance`): every bullet or
frontmatter value filed from a user utterance under this spec is stated-by-user
provenance. Tier writes go to `person.md` frontmatter (no bullet, no tag needed — tags
apply to `## Facts`/`## Signal opt-outs` bullets, not scalar frontmatter fields); every
`profile.md` bullet filed under this spec carries `**[stated-by-user]**` per the
contract's tagging rule. Never file an `**[observed-from-behavior]**` bullet from a raw
utterance — that tag is reserved for the draft-diff loop's confirmed style notes
(out of scope here).

## (a) Tier utterances

Trigger: a debrief/voice-note contains a tier assertion about a named person — direct
("Dana is inner-circle", "bump Sarah to close") or in a wake-up-confirmation reply (see
(d)). Valid tier values are `person.md`'s enum: `inner-circle`, `close`, `active`,
`dormant`.

Filing rule:

1. Resolve the named person against `index.json` the same way plan 03's fact-filing
   resolves names (name + calendar-context disambiguation). This spec does not define a
   new matching algorithm — it reuses whatever the debrief skill's person-matching step
   produces.
2. **Unambiguous match:** write `tier: <value>` into that person's frontmatter,
   overwriting any prior `tier` value in place — this is a frontmatter field update, not
   an append, so there is exactly one `tier` value per person at all times, matching
   `person.md`'s frontmatter shape (a table field, not a list).
3. **Ambiguous match** (e.g. two people plausibly named "Dana" in the store, or the
   debrief gives too little context to pick one): **ask, do not write.** Emit the
   plan 03 one-clarifying-question flow ("Which Dana — Dana Whitfield or Dana Ruiz?")
   instead of guessing. This is the same ambiguous-name handling plan 03 already
   specifies for fact filing (see its golden #7, "ambiguous name (two Sarahs)") — tier
   filing reuses it rather than defining a second ambiguity policy. Never write a tier
   to a guessed person and never split the write into "the more likely one, unless
   corrected."
4. **No match** (person not yet in the store): treat as plan 03's new-person flow —
   create the person file first (from template, per plan 03 unit 6), then apply the
   tier write to the new file. Do not silently drop the tier because the person is new.

Tier writes never carry a provenance tag (no bullet is created); the fact that
`person.md` frontmatter has no provenance convention for scalar fields is intentional
per the contract — provenance tagging in this store applies to bullets in `## Facts`,
`## Signal opt-outs`, etc., not to frontmatter key/value pairs.

## (b) Signal opt-outs

Trigger: a debrief/voice-note contains an explicit ask to stop a signal type — global
("stop birthday reminders", "don't nudge me about job changes") or person-scoped ("stop
birthday reminders for Dana").

Filing rule:

1. Map the utterance to a signal-type from plan 05's detector set (this spec does not
   define that set; it consumes whatever plan 05 ships). If the utterance names a signal
   type the detector set does not recognize, ask a clarifying question rather than
   inventing a new signal-type string — an opt-out bullet's `<signal-type>` token must
   match the detector vocabulary exactly, or `packages/attention`'s signal-scan cannot
   match it at suppression time.
2. **Global opt-out** ("stop birthday reminders", no person named): append
   ```
   - **[stated-by-user]** birthday — all
   ```
   to `profile.md`'s `## Signal opt-outs` section.
3. **Person-scoped opt-out** ("stop birthday reminders for Dana"): resolve the named
   person the same way as (a) — ambiguous → ask, no match → new-person flow first, then
   opt-out — and append:
   ```
   - **[stated-by-user]** birthday — [[dana-whitfield]]
   ```
   using the resolved slug.
4. **Append, never rewrite the section.** If an equivalent opt-out bullet already exists
   (same signal-type, same scope — `all` or the same `[[slug]]`), this is a no-op, not a
   duplicate append — check the section's existing bullets before appending. If the new
   opt-out is a strict widening of an existing one (e.g. store already has `birthday —
   [[dana-whitfield]]` and the user now says "stop all birthday reminders"), append the
   new `all` bullet and leave the narrower one in place — `## Signal opt-outs` is a set
   of suppression rules, a redundant narrower rule alongside a broader one is harmless
   and removing it is not this spec's job (no destructive edits to a section from an
   utterance that didn't ask for removal).
5. An opt-out is never encoded any other way (never a `ranking-weights.json` entry,
   never a tier change, never a `person.md` edit) — per the contract, opt-outs suppress
   at the detector, before ranking.

## (c) Priorities and cadence wishes

Trigger: a debrief/voice-note contains a freeform stated priority ("family first this
quarter") or a stated rhythm ask ("quarterly with the Michigan crowd") that does not fit
the deterministic opt-out grammar in (b).

Filing rule: append one bullet to the matching section —
```
- **[stated-by-user]** <utterance, lightly cleaned up, not paraphrased into a different
  claim> (<capture date, YYYY-MM-DD>)
```
to `## Priorities` for priority statements, `## Cadence wishes` for rhythm statements.
Always append; never rewrite or merge with an existing bullet, even if it appears to
supersede one — profile.md is an append/update log of specific bullets, not a
synthesized summary, so the record of what the user said and when stays intact. (If the
user later says something that contradicts an earlier priority, both bullets stand;
`packages/query` and any human reading the file can see the dated sequence and judge
which is current. This spec does not define priority conflict resolution.)

Distinguishing "priority" from "cadence wish" from "this is actually a tier statement or
opt-out" is a classification judgment call for whatever NL step the debrief skill uses;
this spec only fixes the destination and grammar once classified, not the classifier.

## (d) Tier-change confirmation path (revealed → stated, via confirmation)

This is the one path where a *non-utterance* signal ends in a tier write: `attention`'s
tier-drift detector (per plan 11 unit 10, spec-level) observes person.tier vs. contact
frequency divergence and creates a `wakeup.md` proposal entry (`origin: signal`) asking
something like "Haven't heard from Dana in 4 months despite `inner-circle` — reach out,
or reclassify?" `attention` never writes `person.md` itself (single-writer rule) — it
only creates the proposal wake-up.

Two outcomes once the user responds to that wake-up (via whatever connector renders it
— out of scope here which connector, this spec only covers what ingestion does with the
reply):

- **User confirms the reclassification** ("yeah, move her to `active`"): this is now a
  tier utterance exactly like (a) — ingestion resolves the named person (already
  unambiguous, since the wake-up names exactly the person(s) in question) and writes the
  new `tier` value to that person's frontmatter. The wake-up itself is then dismissed by
  `attention` (lifecycle write, attention's job per the wakeup contract) with whatever
  `dismiss-reason` fits (e.g. `already-handled`); ingestion does not touch the wake-up
  file — `wakeups/` lifecycle fields are attention's sole-writer territory.
- **User declines** ("no, leave her at inner-circle" / "I'll reach out instead" /
  ignores it until it's dismissed): the proposal is **dropped silently**. Ingestion does
  not write anything to `person.md` — no tier change, and critically, **no record of
  the refusal anywhere in `people/`**. Do not file a "user declined reclassification"
  fact, note, or marker on the person file. This is the no-guilt rule
  (`docs/PROJECT-CONTEXT.md` / plan 11 context): a declined proposal leaves no trace
  that could bias a future read of the person file or justify re-asking on a streak.
  The wake-up file itself (in `wakeups/`, not `people/`) retains the normal
  `dismiss-reason` per the wakeup contract — that is attention's queue history, not a
  people-store record, and this spec does not change that.
- **Never re-ask:** a declined tier-drift proposal for a given person must not cause
  another identical proposal to fire again on the next sweep purely because the
  divergence persists — that re-ask suppression is a signal-detector concern (plan 11
  unit 10 / plan 05), not an ingestion filing rule, but ingestion's contribution is
  making sure it never manufactures a workaround record (e.g. a synthetic "opt-out of
  tier-drift for Dana" bullet) to enforce it. If the product later wants an explicit,
  user-visible way to suppress a specific person's tier-drift nudges, that is a new
  stated preference the user must say out loud ("stop suggesting I reclassify Dana") —
  which files exactly like a person-scoped signal opt-out per (b), with signal-type
  `tier-drift`, if and when plan 05 adds `tier-drift` to its detector set. Do not invent
  that opt-out proactively from a decline alone.

## (e) Provenance and write discipline (binding, cross-cutting)

- Every `profile.md` bullet this spec creates is `**[stated-by-user]**` — never
  `**[observed-from-behavior]**`. That tag is reserved for the draft-diff loop's
  post-confirmation style notes, which are out of scope for this spec.
- `person.md` tier writes are frontmatter overwrites (single scalar value, no history
  kept in the file itself — `git log` on the person-store, if the private data dir is
  versioned, is the history mechanism, same as any other frontmatter field).
- All `profile.md` writes under this spec are **append-or-check-then-append of specific
  bullets** — never a section rewrite, never a reordering of existing bullets, never a
  rewrite of an existing bullet's text. The one exception already covered above is
  section-level dedup (5.4): recognizing an already-present equivalent opt-out and
  skipping the append, which is a no-op, not a rewrite.
- Ingestion is `profile.md`'s sole writer, full stop — this spec does not create any new
  writer. `packages/attention` reads `## Signal opt-outs` (signal-scan) and reads
  `## Style notes` for calibration context, but per `packages/core/contracts/profile.md`
  and `docs/DECISIONS.md#preference-provenance`, it only ever *proposes* — the write, per
  (d), always terminates in ingestion.

## (f) Relationship to plan 03

This spec amends plan 03's filing-engine brief (`docs/plans/2026-08-29-03-filing-engine.md`),
which is unbuilt as of this writing. When plan 03's `skills/debrief/SKILL.md` is
implemented, it must incorporate (a)–(e) above as an additional filing lane alongside
its fact/interaction/commitment/wakeup filing — reusing plan 03's existing person-
matching, ambiguity, and one-clarifying-question machinery rather than re-implementing
parallel versions of them. This spec does not define its own person-matching algorithm,
its own new-person flow, or its own ambiguity-question mechanism; it only fixes where
and how tier/opt-out/priority/cadence utterances resolve once plan 03's matching step has
run.

Golden fixtures for this spec (utterance → expected `profile.md`/`person.md` delta,
including the ambiguous-tier case whose expected output is a clarifying question, not a
write) are a separate work unit (plan 11 unit 7) and are not covered by this file.
