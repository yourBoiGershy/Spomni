# Spec: birthday detector

Package: `attention` (plan 05 detector set). Signal `type`: `birthday`. Writes
only `wakeups/signals/<id>.md` (`packages/core/contracts/signal-event.md`,
1.0.0) — one signal event per person per birthday-year, never `people/` or
`interactions/`. Ranking, promotion into a `wakeups/*.md` nudge, and score
weighting belong to `packages/attention/specs/ranking.md`; this spec fixes
only `type`, the confidence rubric, the evidence text, and the due-date rule.

## Inputs

Per sweep, for every person in `people/*.md`:

- Frontmatter `birthday` (`packages/core/contracts/person.md`): `YYYY-MM-DD`
  if the year is known, `--MM-DD` (ISO 8601 reduced form) if only month/day
  is known. Provenance: told-by-user (the user either stated it directly or
  it was captured from a debrief).
- Contact-record capture events from `connectors/contacts-in`
  (`type: contact-record` in `inbox/`) carrying a birthday field, matched to
  a person by email/name resolution already performed by the filing engine.
  Provenance: `[inferred-from-contacts]` — these arrive via the connector
  lane as capture events; the detector never calls a contacts API directly
  (ToS-clean, per `docs/DECISIONS.md`).
- `data/store/profile.md` `## Signal opt-outs`, checked before emission (see
  below).
- Prior `wakeups/signals/*.md` with `type: birthday` for the person, for the
  standing per-year re-emit guard (see below).

## Detection rule

1. For each person with a `birthday` in frontmatter, or a matched
   `contact-record` carrying a birthday, compute the next occurrence of that
   month/day on or after the sweep's run date (year-rollover: a birthday in
   January is "next" even when the sweep runs in late December — compare
   month/day only, wrapping Dec → Jan across the year boundary).
2. Emit a signal if that next occurrence falls within 7 days of the sweep
   run date, inclusive of the run date itself and the 7th day out.
3. If both frontmatter and a contact-record independently supply a
   birthday and they **agree**, treat it as a single high-confidence
   observation (do not raise confidence further — `high` is already the
   ceiling here since it's not two heterogeneous signal types corroborating
   each other, just the same fact from two sources).
4. If frontmatter and a contact-record **disagree** (different month/day),
   frontmatter wins — it is told-by-the-user and outranks an inferred
   source. Log the discrepancy (a line in the sweep run log naming the
   person, the frontmatter date, and the contact-record date) so a human can
   reconcile it later, but emit only one signal event, using the
   frontmatter date. Never emit two competing birthday signals for the same
   person in the same window.
5. A person with neither a frontmatter `birthday` nor a matched
   contact-record birthday produces no signal — the detector never guesses
   a birthday from other text (e.g. a mention of "my birthday is coming
   up" without a date is scheduling-intent or open-thread material, not
   this detector's concern).

## Confidence rubric

| Confidence | Definition | Example |
|---|---|---|
| `high` | `people/<slug>.md` frontmatter states the birthday (with or without a corroborating contact-record) | `birthday: 1965-02-18` in `walter-combs.md` |
| `medium` | Only a `contact-record` capture event supplies the birthday; frontmatter has none | A synced contact carries a birthday field but the user never told the agent directly |

There is no `low` tier for this detector — a birthday is a discrete fact,
not a matter of interpretation; a source either states a date or it
doesn't. `low`-confidence heuristic guessing (e.g. inferring a birthday from
an unrelated mention) is explicitly out of scope (see below).

## Due-date rule

Due date = **the day before the birthday**, per `ranking.md` rule 10 (cited,
not restated). This gives the reminder lead time to actually act on it —
send a card, plan a call — rather than landing same-day. If the birthday
falls within the 7-day window but has already passed by the time a delayed
sweep runs, the due date is the run date itself (never a due date in the
past); ranking's staleness handling takes it from there.

## Opt-out / dedup gates

- **Opt-out** (`data/store/profile.md` `## Signal opt-outs`,
  `packages/core/contracts/profile.md`): `birthday — all` suppresses
  emission for every person, sweep-wide; `birthday — [[slug]]` suppresses
  it for that person only. Checked before emission — an opted-out person's
  birthday produces no signal event at all (unlike scheduling-intent's
  looser "opt-out silences promotion only" rule; birthday has no promotion
  step to distinguish from emission, so the gate sits at emission).
- **Trailing-30-day dedup** (the common-rules default): if a `birthday`
  signal event already exists for this `(person, type: birthday)` pair
  within the trailing 30 days, don't re-emit. In practice this is
  subsumed by the standing per-year rule below, but it's the same
  mechanism as every other detector for cross-checker consistency.
- **Standing per-year rule:** additionally, if a `wakeups/*.md` entry with
  `signal-type: birthday` already exists for this person with a `due` date
  in the current birthday year (pending or already fired), do not re-emit
  — whether or not that entry is still inside the 30-day dedup window. A
  birthday only needs one wake-up per year regardless of how many sweeps
  run in the 7-day lead-up.

## Evidence format

```
Birthday <MM-DD> [stated-by-user] (people/<slug>.md)
```

or, for a contact-record-only match:

```
Birthday <MM-DD> [inferred-from-contacts] (source-capture: <capture-id>)
```

Evidence never restates the discrepancy-log line from detection rule 4 —
that's a sweep-log artifact, not signal-event evidence.

## Example scenarios

1. **Full-date, high confidence, promotes with ammunition.** Sweep runs
   2026-08-29 (fixture reference date, not a real match — for illustration
   assume Walter Combs' `birthday: 1965-02-18` falls within 7 days of the
   sweep date). `people/walter-combs.md` states the birthday directly →
   `confidence: high`, evidence `Birthday 02-18 [stated-by-user]
   (people/walter-combs.md)`, due = 02-17. Per the rarity note below, the
   promoted nudge is expected to lead with ammunition already on file —
   the fishing trip up north and the truck research open thread from
   `interactions/2026-08-05-walter-combs.md` — not a bare "it's his
   birthday."
2. **Reduced date, close tier.** `people/ben-whitmore.md` has
   `birthday: --06-22` (year unknown). If 06-22 falls within 7 days of the
   sweep date, emit `confidence: high` (frontmatter-stated, year-unknown
   doesn't lower confidence — only source lowers it), evidence
   `Birthday 06-22 [stated-by-user] (people/ben-whitmore.md)`, due = 06-21.
3. **No birthday on file, contact-record fills the gap.** `Ayesha Malik`
   has no `birthday` field in her person file. A `contact-record` capture
   event from `contacts-in` resolves to her by email and carries a
   birthday. Emit `confidence: medium`, evidence
   `Birthday <MM-DD> [inferred-from-contacts] (source-capture:
   <capture-id>)`. If Ayesha's frontmatter is later updated by the filing
   engine with a told-by-user birthday that disagrees, the next sweep
   follows detection rule 4: frontmatter wins, discrepancy logged, no
   second signal emitted for the same window.

## Out of scope

- Guessing or inferring a birthday from unstructured text (a message
  mentioning "my birthday party" with no date). Requires a structured
  `birthday` field, told-by-user or contact-record.
- Calling any contacts/enrichment API directly from this detector — inputs
  arrive only as capture events already filed by `connectors/contacts-in`
  (ToS-clean, per `docs/DECISIONS.md`).
- Gift suggestions, card-sending automation, or any drafting — this spec
  covers detection only; drafting belongs to the query/drafting surface.
- Recurring-reminder scheduling beyond the current year's occurrence — each
  year's birthday is detected fresh by a later sweep, not pre-scheduled.
- Ranking, scoring, and promotion mechanics — see `ranking.md`.
