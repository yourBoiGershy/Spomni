# Spec: onboarding tiering seed

> **Superseded in part (plan 30, 2026-08-29).** The 'Tier suggestions
> (deterministic scoring model)' section is superseded by
> `packages/core/contracts/relationship-scoring.md` 1.0.0 (judgment with
> priors) and `specs/review-tiers.md`; `scripts/suggest-tiers.sh` is
> retained only for the legacy seed test suite. The insufficient-data
> gate, the 20-person cap, the one-session/no-backlog rule, confirm/
> adjust/skip semantics, and the no-guilt framing remain binding and are
> inherited by review-tiers.

> **Superseded further (plan 31, 2026-08-30 —
> `docs/plans/2026-08-30-31-deterministic-filing-cold-start-priors.md`
> D7).** The model of record for the cold-start flow is now
> `packages/ingestion/skills/onboarding-seed/SKILL.md` plus
> `specs/review-tiers.md`, not the per-person confirmation batch described
> below. Sequence steps 4–6 and the whole "Presentation rule" section are
> superseded: "Filing produces interactions" (step 2) is now three
> sub-steps — deterministic triage, deterministic structured filing
> (`scripts/file-structured.sh`, `specs/structured-filing.md`, D1–D3, no
> tier/kind opinion either), then model filing for the free-text
> remainder; steps 4–6 (frequency-derived suggestion → batched
> presentation → per-person confirm/adjust/skip before any write) are
> replaced by one `/review-tiers --all` cold-start invocation, which (a)
> auto-adopts a `status: provisional` `user-model.md` with no dialogue
> when one is absent (D6) and (b) writes both a derived `kind` and a
> derived `tier` — `tier_source: derived` / `kind_source: derived`,
> `person@^1.2.0` (D4) — for every person that clears its scope/gate,
> ending in a correction digest rather than a blocking per-person
> confirmation. A stated correction, at any time, outranks a derived write
> and sticks (D5); a `--source derived` write can never overwrite
> `tier_source: stated-by-user` (`person-set-tier.sh`, D4). The
> insufficient-data gate, the 20-person cap, the one-session/no-backlog
> rule, and the no-guilt framing survive into review-tiers' own version of
> these rules (see that spec) — only the *confirmation-before-write* model
> is gone. The "Tier suggestions (deterministic scoring model)" section
> below and its participation-derivation inputs are unaffected by this
> note: they remain exactly as plan 30 left them, a read-only diagnostic
> (`scripts/suggest-tiers.sh`, not run by default) for comparing the
> legacy frequency-only score against review-tiers' semantic judgment.

> **Superseded further still (plan 32, 2026-08-30 —
> `docs/plans/2026-08-30-32-thread-summaries-one-call-per-thread.md` D5).**
> Within onboarding-seed's step 2, the model-filing sub-step no longer sees
> `chat-message` events at all: those file through one model call per
> thread (`scripts/summarize-thread.sh`, `specs/thread-summary.md`) plus a
> deterministic writer (`scripts/file-thread.sh`, D2/D3), never the debrief
> skill's per-day episode-split model pass this section's step 2 note above
> still describes for non-chat free text. This is a running-cost cut only
> (one call + one script pass per thread, replacing a per-day agentic
> filing task); it changes nothing about the tier-suggestion scoring model
> below or its inputs — `stats.json`/`build-stats.sh` read the resulting
> `interactions/*.md` files identically either way.

> **Progress narration (plan 31 amendment).** The session-driven flow
> above is also bound by `packages/ingestion/skills/onboarding-seed/
> SKILL.md`'s "Progress narration (binding)" section: before each step/
> sub-step it prints one `▶ Step N(x) — <what's about to happen>` line,
> and after it one or two `✓ Step N(x) <elapsed>s — <what was found>`
> lines sourced only from that step's own script summary line, never
> invented numbers — a pure running-cost cut so the user never has to ask
> what's happening mid-run. This spec does not restate that contract; the
> SKILL.md is the model of record for it.

Status: spec (plan 11 unit 13, cold-start phase; amended by plan 24 unit 2 —
6-month configurable window + participation-signal scoring). Package:
`packages/ingestion` (the confirmation write, per the single-writer rule)
triggered once at first-run onboarding, downstream of the three direct
lanes' backfill modes — `packages/connectors/gmail-in` / `calendar-in`
(skill backfill modes) and `packages/connectors/beeper-in` (`--backfill`),
built by plan 24 (`docs/plans/2026-08-29-24-onboarding-backfill-priority-seeding.md`)
— and `packages/core/scripts/build-stats.sh`. This spec does not redefine
backfill mode or the filing-confirmation write path — it only fixes the
sequence, the frequency-and-participation-to-tier mapping, and the
presentation/no-guilt rules that sit between them.

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

1. **Backfill sweeps run.** The three direct lanes' backfill modes —
   `packages/connectors/gmail-in` / `calendar-in` (skill backfill modes,
   date-range window, isolated checkpoint namespace) and
   `packages/connectors/beeper-in` (`--backfill`) — run once against the
   connected accounts, producing normalized `inbox/` capture events the same
   shape incremental sweeps produce — this spec does not change capture-event
   shape. See "Window" below for the backfill window default and its
   configuration.
2. **Filing produces interactions.** The filing engine ingests those capture
   events through its normal path, creating `people/<slug>.md` (new-person
   flow, per `stated-preference-filing.md` (a).4) and `interactions/*.md`
   files. No `tier` is set on any newly-created person file at this stage —
   creation from a capture event carries no tier opinion. A backfilled
   multi-day `chat-message` event files as one interaction per active
   conversation day, not one interaction total, per the debrief skill's
   episode-split rule (`packages/ingestion/skills/debrief/SKILL.md` §5b-
   episodes) — this is what keeps backfilled touchpoint counts genuine.
3. **`build-stats.sh` runs**, producing `stats.json`
   (`packages/core/contracts/derived-index.md`) with, per slug: `touchpoints`,
   `median_gap_days`, `first_interaction`, `last_interaction`,
   `interactions[]`.
4. **Frequency-and-participation-derived tier suggestions are computed**
   (deterministic scoring model, below) from that `stats.json` snapshot plus
   participation signals derived from the preserved raw capture events — a
   suggestion is a value held in memory / the onboarding session's working
   state, **never written to `people/<slug>.md`** until the user confirms it
   in step 5.
5. **Suggestions are presented in one batch**, the user confirms/adjusts/skips
   each (presentation rule, below).
6. **Confirmed tiers are filed by ingestion** as stated-by-user, via the exact
   write in `stated-preference-filing.md` (a).2 (frontmatter `tier` overwrite,
   unambiguous — the person is already resolved, since the batch is built
   from `stats.json` slugs, not free text). Skipped or unconfirmed people are
   left with no `tier` key at all (see "Untiered is a valid end state" below).

Steps 1–3 are the direct lanes' backfill modes' output and
`build-stats.sh`'s normal operation respectively — this spec consumes both
as-is and does not amend either.

## Window

Backfill covers a **default 6-month** window, user-configurable via
`packages/core/contracts/onboarding-backfill.md`'s `window_months` key (an
integer ≥ 1, defaulting to 6 when the config file or key is absent). All
three backfill lanes and the participation derivation below (see
"Participation signals") honor the same configured window — there is no
per-lane override.

## Tier suggestions (deterministic scoring model)

Computed once per person from that person's `stats.json` entry plus
participation signals derived at seed time, over the window covered by the
backfill (see "Window" above).

**Insufficient-data gate (evaluated first):** if `touchpoints < 2`, there is
no `median_gap_days` (per `derived-index.md`, a gap requires two dates) — the
person is **excluded from the suggestion batch entirely**. Zero or one
backfilled touchpoint is not evidence of a rhythm; do not guess a tier from a
single data point, and do not suggest `dormant` as a default either (that is
still a guess about a real category the user must confirm, not a null value).
These people remain untiered and are not offered a suggestion in this pass.

**Base band**, for every person with `touchpoints >= 2`, from
`median_gap_days` (uses the exact gap thresholds
`packages/attention/specs/tier-drift.md`'s expected-cadence table already
establishes for these same tier boundaries, so a person seeded here and later
drifting is measured against the same yardstick; ties at a boundary fall to
the *closer* (warmer) tier — e.g. exactly `21` maps to `inner-circle`, not
`close`):

| `median_gap_days` | Base band | Points |
|---|---|---|
| `<= 21` | `inner-circle` | 3 |
| `> 21` and `<= 45` | `close` | 2 |
| `> 45` and `<= 90` | `active` | 1 |
| `> 90` | `dormant` | 0 |

There is no ambiguous case: every integer `median_gap_days` value maps to
exactly one row.

**Participation signals**, derived at seed time from the preserved raw
capture events via interactions' `source-capture` links (per
`packages/core/contracts/interaction.md`) — these signals are derived,
never written to any file; stated always outranks derived, per plan 15 /
`docs/DECISIONS.md#preference-provenance`:

- **`user-engaged` (+2):** at least one linked raw event in-window authored
  by a `self` identity (from the onboarding-backfill config) with this
  person a participant.
- **`co-attended` (+1):** at least one `stats.json` interaction with
  `calendar: true` in-window.
- **`silent-group` (class LOW, score forced to 0):** no `user-engaged`, no
  `co-attended`, and at least one linked raw event is a group event (three
  or more participant hints).
- **`never-answered` (class VERY-LOW, score forced to −1):** no
  `user-engaged`, no `co-attended`, no linked group event — i.e. all
  touchpoints are direct inbound the user never answered.

Boosts (`user-engaged`, `co-attended`) are cumulative. The two penalty
classes (`silent-group`, `never-answered`) apply only when both boosts are
absent, and are mutually exclusive by the group test — a person can be in at
most one penalty class.

**Final score** = clamp(base band points + boost points, −1, 3); the penalty
classes set the score directly (0 for `silent-group`, −1 for
`never-answered`), overriding the base band's points. Suggested tier from
final score:

| Final score | Suggested tier |
|---|---|
| `3` | `inner-circle` |
| `2` | `close` |
| `1` | `active` |
| `<= 0` | `dormant` |

Note: a person with two or more touchpoints all being unanswered cold
inbound gets the `never-answered` (VERY-LOW) class, a final score of −1, and
a suggested tier of `dormant`, ranked last in the batch (see "Ordering"
below) — this is distinct from a single cold pitch, which never reaches
this scoring step at all because it is excluded by the insufficient-data
gate above.

**Breakdown string**, carried by every suggestion, for presentation and for
fixture-checking:

```
suggested: <tier> | base: <band> (median_gap_days=<n>) | signals: <comma list with deltas, e.g. user-engaged(+2), co-attended(+1)>
```

Penalty classes render in the `signals` position as `class: never-answered
(very low)` or `class: silent-group (low)` instead of a delta list. A person
with no boosts and no penalty class renders `signals: none`.

This scoring model is intentionally the only judgment this spec makes from
data alone, and it never writes anything by itself — it only populates what
is offered to the user in step 5.

## Presentation rule

- **One session, not a backlog.** All suggestions from a given backfill run
  are batched and presented together in a single onboarding pass — there is
  no follow-up prompt for suggestions the user didn't get to, no "you still
  have N people to review" resurfacing on a later day. If the user closes the
  session partway through, whatever was not confirmed in that pass is treated
  exactly like a skip (see below) — not queued for a second pass.
- **Cap and ordering.** Present at most 20 people, ordered by final score
  descending (warmest/most-engaged first), ties broken by `median_gap_days`
  ascending, then `touchpoints` descending, then slug ascending. If fewer
  than 20 people clear the
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

Given a fixture `stats.json` (per-slug `touchpoints`, `median_gap_days`,
`interactions[]` with `calendar` flags), a fixture set of preserved raw
capture events linked via `source-capture`, and a fixture cap/ordering
scenario, a checker can hand-verify without judgment calls:

1. Which people clear the insufficient-data gate (`touchpoints >= 2`).
2. Each cleared person's derived participation signals from the fixture raw
   events — `user-engaged`, `co-attended`, `silent-group`, or
   `never-answered`, per the definitions above.
3. Each cleared person's exact base band, final score (clamped, with penalty
   classes overriding as specified), and suggested tier.
4. The presented batch's exact order (final score descending, then
   `median_gap_days` ascending, then `touchpoints` descending, then slug
   ascending), including where penalty-class people fall, and which people
   fall inside vs. outside the 20-person cap.
5. Each presented suggestion's exact breakdown string, matching the format
   above (including `class: ...` rendering for penalty classes and
   `signals: none` where no signal applies).
6. That a confirmed/adjusted person ends the pass with exactly the tier the
   user chose (suggestion or override) written to `people/<slug>.md`, and a
   skipped or capped-out person ends the pass with no `tier` key at all.

## Out of scope

- Backfill mode itself (date-range window, checkpoint isolation) — the three
  direct lanes' backfill modes (`gmail-in` / `calendar-in` skill backfill
  modes, `beeper-in --backfill`), consumed as-is here.
- The `onboarding-backfill.tsv` config format and `window_months` validation
  — `packages/core/contracts/onboarding-backfill.md`, consumed as-is here.
- The participation-derivation script's implementation details (identity
  resolution against `self`, group-event participant-hint counting) —
  `packages/ingestion/scripts/derive-participation.sh`, consumed as-is here;
  this spec only specifies the scoring model those signals feed.
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
