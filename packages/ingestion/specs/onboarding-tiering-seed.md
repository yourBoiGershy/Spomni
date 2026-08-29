# Spec: onboarding tiering seed

Status: spec (plan 11 unit 13, cold-start phase). Package: `packages/ingestion`
(the confirmation write, per the single-writer rule) triggered once at
first-run onboarding, downstream of `packages/connectors/gmail-in` /
`packages/connectors/calendar-in`'s backfill mode (plan 11 unit 12,
spec-level as of this writing) and `packages/core/scripts/build-stats.sh`.
This spec does not redefine backfill mode or the filing-confirmation write
path — it only fixes the sequence, the frequency-to-tier mapping, and the
presentation/no-guilt rules that sit between them.

**Backfill deferral note:** backfill mode itself is deferred by plan 17 (the
2026-08-29 direct-Google-lanes plan under `docs/plans/`) pending its Phase 3
tool-surface check on the new first-party `gmail-in` / `calendar-in` lanes —
this spec's sequence is otherwise unchanged and takes effect once that
backfill mode ships.

## Scope

A fresh install has no `tier` set on any `people/<slug>.md` — every person is
untiered, and warmth-based ranking (`docs/PROJECT-CONTEXT.md`'s warmth ×
rarity ranking) has nothing to prioritize on. This spec closes that cold-start
gap in one bounded, human-confirmed pass: backfilled interaction history
produces frequency stats, frequency stats produce *suggested* tiers, and the
user confirms, adjusts, or skips each suggestion. Nothing is ever tier-written
without that confirmation — this is the same stated-by-user provenance rule
`packages/ingestion/specs/stated-preference-filing.md` already defines for
tier utterances; onboarding is a new *trigger* for that existing write path,
not a new write path.

## Sequence

1. **Backfill sweeps run.** `packages/connectors/gmail-in` / `calendar-in`'s
   backfill mode (gmail-sweep / calendar-sweep, date-range window, isolated
   checkpoint namespace per plan 11 unit 12) runs once against the connected
   accounts, producing normalized `inbox/` capture events the same shape
   incremental sweeps produce — this spec does not change capture-event shape
   or the backfill window default. (Backfill mode is deferred pending plan
   17's Phase 3 tool-surface check — see the deferral note above.)
2. **Filing produces interactions.** The filing engine ingests those capture
   events through its normal path, creating `people/<slug>.md` (new-person
   flow, per `stated-preference-filing.md` (a).4) and `interactions/*.md`
   files. No `tier` is set on any newly-created person file at this stage —
   creation from a capture event carries no tier opinion.
3. **`build-stats.sh` runs**, producing `stats.json`
   (`packages/core/contracts/derived-index.md`) with, per slug: `touchpoints`,
   `median_gap_days`, `first_interaction`, `last_interaction`,
   `interactions[]`.
4. **Frequency-derived tier suggestions are computed** (deterministic mapping,
   below) from that `stats.json` snapshot — a suggestion is a value held in
   memory / the onboarding session's working state, **never written to
   `people/<slug>.md`** until the user confirms it in step 5.
5. **Suggestions are presented in one batch**, the user confirms/adjusts/skips
   each (presentation rule, below).
6. **Confirmed tiers are filed by ingestion** as stated-by-user, via the exact
   write in `stated-preference-filing.md` (a).2 (frontmatter `tier` overwrite,
   unambiguous — the person is already resolved, since the batch is built
   from `stats.json` slugs, not free text). Skipped or unconfirmed people are
   left with no `tier` key at all (see "Untiered is a valid end state" below).

Steps 1–3 are the plan 11 unit 12 backfill mode's output and
`build-stats.sh`'s normal operation respectively — this spec consumes both
as-is and does not amend either.

## Frequency-derived tier suggestions (deterministic mapping)

Computed once per person from that person's `stats.json` entry, using the
window covered by the backfill (default 12 months per plan 11 unit 12 — this
spec does not override that default).

**Insufficient-data gate (evaluated first):** if `touchpoints < 2`, there is
no `median_gap_days` (per `derived-index.md`, a gap requires two dates) — the
person is **excluded from the suggestion batch entirely**. Zero or one
backfilled touchpoint is not evidence of a rhythm; do not guess a tier from a
single data point, and do not suggest `dormant` as a default either (that is
still a guess about a real category the user must confirm, not a null value).
These people remain untiered and are not offered a suggestion in this pass.

**Band mapping**, for every person with `touchpoints >= 2` (uses the exact
gap thresholds `packages/attention/specs/tier-drift.md`'s expected-cadence
table already establishes for these same tier boundaries, so a person seeded
here and later drifting is measured against the same yardstick):

| `median_gap_days` | Suggested tier |
|---|---|
| `<= 21` | `inner-circle` |
| `> 21` and `<= 45` | `close` |
| `> 45` and `<= 90` | `active` |
| `> 90` | `dormant` |

Ties at a boundary fall to the *closer* (warmer) tier — e.g. exactly `21`
maps to `inner-circle`, not `close` — matching the table's `<=` operators
above (there is no ambiguous case: every integer `median_gap_days` value maps
to exactly one row).

This mapping is intentionally the only judgment this spec makes from data
alone, and it never writes anything by itself — it only populates what is
offered to the user in step 5.

## Presentation rule

- **One session, not a backlog.** All suggestions from a given backfill run
  are batched and presented together in a single onboarding pass — there is
  no follow-up prompt for suggestions the user didn't get to, no "you still
  have N people to review" resurfacing on a later day. If the user closes the
  session partway through, whatever was not confirmed in that pass is treated
  exactly like a skip (see below) — not queued for a second pass.
- **Cap and ordering.** Present at most 20 people, most-frequent first
  (ascending `median_gap_days`, i.e. warmest suggestion first; ties broken by
  descending `touchpoints`). If fewer than 20 people clear the
  insufficient-data gate, present all of them. If more than 20 clear the
  gate, the remaining people beyond the cap are **not** presented and are not
  queued for later — they stay untiered exactly like a skip, for the same
  no-backlog reason. (Rationale for the cap: a five-minute confirmation pass
  is the design target — `docs/plans/2026-08-29-11-preference-personalization.md`
  unit 13 — and a longer list defeats that; the cap trades completeness for a
  bounded, low-friction first session. There is no mechanism in this spec to
  "run the pass again for the rest" — that would reintroduce the backlog this
  spec is designed to avoid. A person left out by the cap gets tiered
  normally later, either by an explicit stated tier utterance
  (`stated-preference-filing.md` (a)) or, if their frequency later crosses a
  tier-drift threshold after they do get a tier some other way, by that
  detector — never by a second onboarding pass.)
- **Per-person action, one of three:**
  - **Confirm** the suggested tier as-is.
  - **Adjust** to a different tier value (the user may pick any of the four
    enum values, not just the adjacent ones — the suggestion is a starting
    point, not a constraint).
  - **Skip** — no tier is set for this person, now or automatically later.
  Confirm and adjust are both, at the filing layer, the same event: an
  explicit user-stated tier value for a named, unambiguous person. There is
  no distinct "accepted the suggestion verbatim" provenance — both are
  ordinary stated-by-user tier writes per `stated-preference-filing.md` (a).2.
- **No-guilt framing (binding).** These suggestions are derived from observed
  backfilled behavior, not from the user's stated intent — the same
  revealed/stated split `docs/DECISIONS.md#preference-provenance` draws
  everywhere else in this plan. Presenting them must never frame a low-suggested
  tier, a skip, or an untiered/excluded-by-cap person as a failing, an
  oversight, or something to fix:
  - Never phrase a suggestion as "you've been neglecting X" or similarly
    guilt-inflected language; a `dormant` suggestion is a neutral read of
    contact frequency, not a verdict.
  - Never single out or flag people the batch excluded for insufficient data
    or the cap as "still needs attention" — silence about them is correct,
    matching the standing no-badges/no-streaks/no-backlog-guilt principle in
    `CLAUDE.md`.
  - A skip carries no consequence and produces no follow-up nudge, ever, from
    this pass specifically — see "Untiered is a valid end state" below for
    the durable-state rule.

## Untiered is a valid end state

A person with no `tier` key is not an error, not a to-do item, and not
implicitly `dormant` — `person.md`'s `tier` field is optional
(`packages/core/contracts/person.md`) precisely so this state can exist
cleanly. This spec never:

- auto-sets a tier for anyone who was skipped, excluded by the cap, or
  excluded by the insufficient-data gate;
- schedules or triggers a second onboarding-style batch to "catch up" the
  people left untiered by this pass;
- creates a wake-up, reminder, or any other artifact nagging the user to go
  finish tiering people later.

An untiered person is simply invisible to tier-dependent ranking inputs until
they either get an explicit stated tier (`stated-preference-filing.md` (a))
or accumulate enough history that a future stated tier utterance or normal
product flow assigns one — never this onboarding pass revisiting them.

## Interaction with tier-drift (one-time seed, not an ongoing loop)

Once a tier is confirmed by this pass, it is filed as an ordinary `tier`
value indistinguishable from a tier stated any other way — there is no
"onboarding-suggested" marker or separate provenance carried forward. From
that point on, `packages/attention/specs/tier-drift.md`'s detector is what
notices *later* divergence between that tier and observed frequency (its own
independent thresholds, sweep-driven, ongoing) and proposes a reclassify/
reach-out nudge through its own confirmation path
(`stated-preference-filing.md` (d)). This spec's mapping table intentionally
reuses tier-drift's exact gap boundaries (21/45/90 days) so a person's
onboarding-seeded tier and their first possible drift signal are measured
against the same yardstick — but the mapping computation itself runs exactly
once, at onboarding, and is never re-invoked by a later sweep. Any ongoing
tiering pressure after onboarding is tier-drift's job, not this spec's.

## Deterministic fixture-checkability

Given a fixture `stats.json` (per-slug `touchpoints`, `median_gap_days`) and a
fixture cap/ordering scenario, a checker can hand-verify without judgment
calls:

1. Which people clear the insufficient-data gate (`touchpoints >= 2`).
2. Each cleared person's exact suggested tier from the band table.
3. The presented batch's exact order (ascending `median_gap_days`, ties by
   descending `touchpoints`) and which people fall inside vs. outside the
   20-person cap.
4. That a confirmed/adjusted person ends the pass with exactly the tier the
   user chose (suggestion or override) written to `people/<slug>.md`, and a
   skipped or capped-out person ends the pass with no `tier` key at all.

## Out of scope

- Backfill mode itself (date-range window, checkpoint isolation) — plan 11
  unit 12's spec, consumed as-is here.
- The mechanics of the confirmation write (person resolution, frontmatter
  overwrite, ambiguity handling) — `stated-preference-filing.md` (a), reused
  as-is; this spec only supplies the suggestions that feed that path's input.
- Any tier-drift detector behavior after onboarding — `tier-drift.md`, unowned
  by this spec.
- Re-running this pass, partially or fully, after the first onboarding
  session — permanently out of scope per the no-backlog rule above; a later
  plan may add an explicit user-invoked "review tiers" flow, but that would
  be a new, separately-specced feature, not an extension of this one-time
  seed.
